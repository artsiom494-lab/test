#!/bin/bash

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <secret-name> <vault-path>"
  echo "Example: $0 app-db secret/data/apps/database"
  exit 1
fi

SECRET_NAME=$1
VAULT_PATH=$2
MANIFESTS_DIR="manifests/${SECRET_NAME}"
SOPS_KEY="../sops-age-key/age.pub"

# Проверяем наличие ключей
PRIV_KEY="${SOPS_KEY%.pub}.key"

if [ -f "$SOPS_KEY" ]; then
  # Используем публичный ключ напрямую
  PUB_KEY=$(cat "$SOPS_KEY")
  echo "📄 Using public key from: $SOPS_KEY"
elif [ -f "$PRIV_KEY" ]; then
  # Генерируем публичный ключ из приватного
  PUB_KEY=$(age-keygen -y "$PRIV_KEY")
  echo "🔑 Generating public key from private key: $PRIV_KEY"
else
  echo "❌ No key found!"
  echo "Expected either:"
  echo "  - $SOPS_KEY (public key)"
  echo "  - $PRIV_KEY (private key)"
  echo ""
  echo "To generate keys:"
  echo "  age-keygen -o sops-age-key/age.key"
  echo "  age-keygen -y sops-age-key/age.key > sops-age-key/age.pub"
  exit 1
fi

mkdir -p $MANIFESTS_DIR

echo "=== Creating SOPS secret: $SECRET_NAME ==="
echo "Vault path: $VAULT_PATH"
echo "Public key: ${PUB_KEY:0:20}..."
echo ""
echo "Enter key-value pairs (empty key to finish):"

# Собираем данные
DATA_FILE=$(mktemp)
echo "" > $DATA_FILE

while true; do
  read -p "Key: " KEY
  [ -z "$KEY" ] && break
  
  read -sp "Value: " VALUE
  echo
  
  echo "$KEY=$VALUE" >> $DATA_FILE
done

if [ ! -s $DATA_FILE ]; then
  echo "No data provided!"
  rm $DATA_FILE
  exit 1
fi

echo ""
echo "Data to be stored:"
cat $DATA_FILE

# 1. Создаем .sops.yaml для этого секрета
cat > $MANIFESTS_DIR/.sops.yaml << SOPS_CONFIG
creation_rules:
  - age: "$PUB_KEY"
SOPS_CONFIG

# 2. Создаем plain secret
cat > $MANIFESTS_DIR/${SECRET_NAME}-plain.yaml << PLAIN
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: default
type: Opaque
stringData:
PLAIN

while IFS='=' read -r KEY VALUE; do
  [ -z "$KEY" ] && continue
  echo "  $KEY: $VALUE" >> $MANIFESTS_DIR/${SECRET_NAME}-plain.yaml
done < $DATA_FILE

# 3. Зашифровываем с SOPS
echo ""
echo "🔐 Encrypting with SOPS..."
cd $MANIFESTS_DIR
sops --encrypt --in-place ${SECRET_NAME}-plain.yaml
mv ${SECRET_NAME}-plain.yaml ${SECRET_NAME}-encrypted.yaml
cd ../..

# 4. Создаем JSON для Vault
JSON_FILE=$(mktemp)
echo '{"data": {' > $JSON_FILE
FIRST=true
while IFS='=' read -r KEY VALUE; do
  [ -z "$KEY" ] && continue
  if [ "$FIRST" = false ]; then
    echo -n ', ' >> $JSON_FILE
  fi
  # Экранируем специальные символы JSON
  ESCAPED_VALUE=$(printf '%s' "$VALUE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$VALUE\"")
  echo -n "\"$KEY\": $ESCAPED_VALUE" >> $JSON_FILE
  FIRST=false
done < $DATA_FILE
echo '}}' >> $JSON_FILE

JSON_CONTENT=$(cat $JSON_FILE | tr -d '\n')

# 5. Создаем KSOPS генератор
cat > $MANIFESTS_DIR/ksops-generator.yaml << KSOPS
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ${SECRET_NAME}-generator
files:
  - ./${SECRET_NAME}-encrypted.yaml
KSOPS

# 6. Создаем Job для синхронизации с Vault
cat > $MANIFESTS_DIR/${SECRET_NAME}-sync.yaml << JOB
apiVersion: batch/v1
kind: Job
metadata:
  name: ${SECRET_NAME}-to-vault
  namespace: default
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      containers:
      - name: vault-sync
        image: alpine/curl:latest
        env:
        - name: VAULT_ADDR
          value: "https://vault.vault.svc:8200"
        - name: VAULT_SKIP_VERIFY
          value: "true"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -ex
          echo "=== Syncing ${SECRET_NAME} to Vault ==="
          
          # 1. Проверяем наличие токена
          echo "1. Checking Vault token..."
          if [ ! -f /vault-token/token ]; then
            echo "❌ Vault token not found at /vault-token/token"
            ls -la /vault-token/
            exit 1
          fi
          
          VAULT_TOKEN=\$(cat /vault-token/token)
          echo "Token exists (first 10 chars): \${VAULT_TOKEN:0:10}..."
          
          # 2. Проверяем доступность Vault
          echo "2. Checking Vault connectivity..."
          curl -k -s -H "X-Vault-Token: \$VAULT_TOKEN" \\
            "\$VAULT_ADDR/v1/sys/health" || {
            echo "❌ Cannot connect to Vault"
            exit 1
          }
          
          # 3. Читаем данные из смонтированного секрета
          echo "3. Reading data from mounted secret..."
          
          # Создаем JSON из всех файлов в директории
          echo '{"data": {' > /tmp/new-data.json
          FIRST=true
          for FILE in /tmp/k8s-secret/*; do
            KEY=\$(basename "\$FILE")
            VALUE=\$(cat "\$FILE")
            
            if [ "\$FIRST" = false ]; then
              echo -n ', ' >> /tmp/new-data.json
            fi
            # Экранируем JSON
            ESCAPED_VALUE=\$(echo "\$VALUE" | sed 's/"/\\\\"/g')
            echo -n "\"\$KEY\": \"\$ESCAPED_VALUE\"" >> /tmp/new-data.json
            FIRST=false
            
            echo "  Found key: \$KEY (value length: \${#VALUE})"
          done
          echo '}}' >> /tmp/new-data.json
          
          echo "Generated JSON:"
          cat /tmp/new-data.json
          
          # 4. Проверяем существующий секрет в Vault
          echo "4. Checking existing secret in Vault..."
          EXISTING_RESPONSE=\$(curl -k -s -w "\\n%{http_code}" \\
            -H "X-Vault-Token: \$VAULT_TOKEN" \\
            "\$VAULT_ADDR/v1/${VAULT_PATH}" 2>/dev/null || echo "{\\"errors\\":[]}")
          
          HTTP_CODE=\$(echo "\$EXISTING_RESPONSE" | tail -n1)
          EXISTING_BODY=\$(echo "\$EXISTING_RESPONSE" | head -n-1)
          
          echo "Vault response code: \$HTTP_CODE"
          
          # 5. Проверяем хэш
          NEW_HASH=\$(md5sum /tmp/new-data.json | cut -d' ' -f1)
          echo "New data hash: \$NEW_HASH"
          
          if [ "\$HTTP_CODE" = "200" ] && echo "\$EXISTING_BODY" | grep -q '"data"'; then
            echo "Existing secret found, comparing..."
            echo "\$EXISTING_BODY" | jq '.data' > /tmp/existing-data.json 2>/dev/null || \\
              echo "\$EXISTING_BODY" > /tmp/existing-data.json
            
            EXISTING_HASH=\$(md5sum /tmp/existing-data.json | cut -d' ' -f1)
            echo "Existing hash: \$EXISTING_HASH"
            
            if [ "\$NEW_HASH" = "\$EXISTING_HASH" ]; then
              echo "✅ Secret already up-to-date in Vault, skipping..."
              exit 0
            fi
            echo "⚠️  Secret exists but differs, updating..."
          else
            echo "📝 Creating new secret in Vault (HTTP code: \$HTTP_CODE)..."
          fi
          
          # 6. Отправляем в Vault
          echo "6. Sending to Vault..."
          RESPONSE=\$(curl -k -s -w "\\n%{http_code}" -X POST \\
            -H "X-Vault-Token: \$VAULT_TOKEN" \\
            -H "Content-Type: application/json" \\
            -d @/tmp/new-data.json \\
            "\$VAULT_ADDR/v1/${VAULT_PATH}" 2>/dev/null)
          
          RESPONSE_CODE=\$(echo "\$RESPONSE" | tail -n1)
          RESPONSE_BODY=\$(echo "\$RESPONSE" | head -n-1)
          
          echo "Response code: \$RESPONSE_CODE"
          echo "Response body: \$RESPONSE_BODY"
          
          if [ "\$RESPONSE_CODE" = "200" ] || [ "\$RESPONSE_CODE" = "204" ]; then
            echo "✅ Successfully synced to Vault"
          else
            echo "❌ Failed to sync to Vault. HTTP: \$RESPONSE_CODE"
            exit 1
          fi
          
          # 7. Проверяем
          echo "7. Verifying..."
          curl -k -s -H "X-Vault-Token: \$VAULT_TOKEN" \\
            "\$VAULT_ADDR/v1/${VAULT_PATH}" | jq .data 2>/dev/null || \\
            curl -k -s -H "X-Vault-Token: \$VAULT_TOKEN" \\
            "\$VAULT_ADDR/v1/${VAULT_PATH}"
        volumeMounts:
        - name: secrets
          mountPath: /tmp/k8s-secret
          readOnly: true
        - name: vault-token
          mountPath: /vault-token
          readOnly: true
      volumes:
      - name: secrets
        secret:
          secretName: ${SECRET_NAME}
      - name: vault-token
        secret:
          secretName: vault-token
      restartPolicy: Never
JOB

# 7. Создаем kustomization.yaml для этого секрета
cat > $MANIFESTS_DIR/kustomization.yaml << KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

generators:
  - ksops-generator.yaml

resources:
  - ${SECRET_NAME}-sync.yaml
KUST

# 8. Создаем/обновляем общий kustomization.yaml
echo ""
echo "Updating main kustomization.yaml..."

# Находим все директории с манифестами
find manifests -name "kustomization.yaml" -type f | \
  sed 's|manifests/||' | \
  sed 's|/kustomization.yaml||' | \
  sort > /tmp/kust-dirs.txt

# Создаем общий kustomization.yaml
cat > kustomization.yaml << MAIN_KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
MAIN_KUST

while read -r DIR; do
  echo "- manifests/$DIR" >> kustomization.yaml
done < /tmp/kust-dirs.txt

# Очистка
rm $DATA_FILE $JSON_FILE /tmp/kust-dirs.txt

echo ""
echo "✅ Successfully created:"
echo "  📁 Directory: $MANIFESTS_DIR/"
echo "  🔐 Encrypted: $MANIFESTS_DIR/${SECRET_NAME}-encrypted.yaml"
echo "  ⚙️  Generator: $MANIFESTS_DIR/ksops-generator.yaml"
echo "  🔄 Sync Job: $MANIFESTS_DIR/${SECRET_NAME}-sync.yaml"
echo "  📋 Kustomize: $MANIFESTS_DIR/kustomization.yaml"
echo ""
echo "📋 Main kustomization.yaml:"
cat kustomization.yaml
echo ""
echo "🚀 To deploy:"
echo "  git add manifests/$SECRET_NAME/"
echo "  git add kustomization.yaml"
echo "  git commit -m 'Add ${SECRET_NAME} secret'"
echo "  git push"
echo ""
echo "🔑 Decryption test:"
echo "  cd $MANIFESTS_DIR && sops --decrypt ${SECRET_NAME}-encrypted.yaml"
