#!/bin/bash

set -e

if [ $# -ne 2 ]; then
  echo "Использование: $0 <имя-секрета> <путь-в-vault>"
  echo "Пример: $0 app-db secret/data/apps/database"
  exit 1
fi

SECRET_NAME=$1
VAULT_PATH=$2
OUTPUT_FILE="manifests/${SECRET_NAME}-secret.enc.yaml"

mkdir -p manifests

echo "=== Создание SOPS-зашифрованного секрета: $SECRET_NAME ==="
echo "Путь в Vault: $VAULT_PATH"
echo ""
echo "Введите пары ключ-значение (пустой ключ для завершения):"

# Создаем временный файл с правильным именем, чтобы SOPS распознал его
TEMP_FILE="${SECRET_NAME}-temp-secret.yaml"
cat > $TEMP_FILE << YAML
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: default
  annotations:
    vault-sync/path: "$VAULT_PATH"
type: Opaque
stringData:
YAML

while true; do
  read -p "Ключ: " KEY
  [ -z "$KEY" ] && break
  
  read -sp "Значение: " VALUE
  echo
  
  # Экранируем спецсимволы в YAML
  SAFE_VALUE=$(echo "$VALUE" | sed -e 's/:/:/g' -e 's/"/\\"/g')
  echo "  $KEY: \"$SAFE_VALUE\"" >> $TEMP_FILE
done

echo ""
echo "Шифрование с помощью SOPS..."

# Проверяем конфигурацию SOPS
if ! command -v sops &> /dev/null; then
  echo "Ошибка: SOPS не установлен!"
  exit 1
fi

# Шифруем файл
if ! sops --encrypt --in-place $TEMP_FILE; then
  echo ""
  echo "Ошибка шифрования! Проверьте:"
  echo "1. Файл ~/.sops.yaml существует"
  echo "2. Правило path_regex: '.*secret.*\.yaml\$' соответствует имени файла"
  echo "3. Возраст-ключ (age key) доступен"
  exit 1
fi

# Перемещаем зашифрованный файл в manifests/
mv $TEMP_FILE $OUTPUT_FILE

# Добавляем в kustomization.yaml
if [ ! -f manifests/kustomization.yaml ]; then
  cat > manifests/kustomization.yaml << KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ${SECRET_NAME}-secret.enc.yaml
- vault-sync-operator.yaml
KUST
else
  # Проверяем, не добавлен ли уже этот файл
  if ! grep -q "${SECRET_NAME}-secret.enc.yaml" manifests/kustomization.yaml; then
    # Добавляем в конец списка resources
    sed -i '/^resources:/a\  - '"${SECRET_NAME}-secret.enc.yaml" manifests/kustomization.yaml
  fi
fi

echo ""
echo "✅ Создан: $OUTPUT_FILE"
echo ""
echo "Для деплоя выполните:"
echo "git add manifests/"
echo "git commit -m 'Добавлен секрет ${SECRET_NAME}'"
echo "git push"