DEPLOY_DATA_HASH=$(sha256sum hash_verified_installer/v1.0.0.sh | cut -d' ' -f1) && echo $DEPLOY_DATA_HASH
DEPLOY_DATA=$(gzip --best --stdout hash_verified_installer/v1.0.0.sh | base64 --wrap=0) && echo $DEPLOY_DATA

DEPLOY_DATA_HASH=$(sha256sum fedora_llama.cpp/v0.5.0.sh | cut -d' ' -f1) && echo $DEPLOY_DATA_HASH
