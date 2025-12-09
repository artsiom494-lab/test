#!/bin/bash
set -e

echo "🔐 Creating encrypted secret for Vault"
echo ""

read -p "Secret name (e.g., app-db): " SECRET_NAME
read -p "Namespace (default): " NAMESPACE
NAMESPACE=${NAMESPACE:-default}
read -p "Vault path (e.g., secret/data/apps/database): " VAULT_PATH

# Создаем директории
mkdir -p manifests/secrets/${NAMESPACE}

# Создаем временный файл с правильным расширением
TEMP_FILE="manifests/secrets/${NAMESPACE}/${SECRET_NAME}.enc.yaml"
TEMP_TMP="${TEMP_FILE}.tmp"

# Создаем шаблон
cat > "$TEMP_TMP" << YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    vaultPath: "${VAULT_PATH}"
type: Opaque
stringData:
YAML

# Собираем данные
echo ""
echo "Enter key-value pairs (empty key to finish):"
while true; do
  read -p "Key: " KEY
  [ -z "$KEY" ] && break
  
  read -sp "Value: " VALUE
  echo ""
  
  # Экранируем кавычки
  SAFE_VALUE=$(echo "$VALUE" | sed 's/"/\\"/g')
  echo "  ${KEY}: \"${SAFE_VALUE}\"" >> "$TEMP_TMP"
done

echo ""
echo "🔒 Encrypting with SOPS..."

# Шифруем
if ! sops --encrypt --in-place "$TEMP_TMP"; then
  echo "❌ Encryption failed!"
  echo "Check:"
  echo "1. Is .sops.yaml present with correct age key?"
  echo "2. Does the file have .enc.yaml extension?"
  rm -f "$TEMP_TMP"
  exit 1
fi

# Переименовываем
mv "$TEMP_TMP" "$TEMP_FILE"

echo ""
echo "✅ Created: ${TEMP_FILE}"
echo ""
echo "📝 Next steps:"
echo "1. git add ${TEMP_FILE}"
echo "2. git commit -m 'Add ${SECRET_NAME} secret'"
echo "3. git push"
echo ""
echo "🔄 ArgoCD will automatically:"
echo "   - Decrypt the secret"
echo "   - Create a Job"
echo "   - Write data to Vault at: ${VAULT_PATH}"
