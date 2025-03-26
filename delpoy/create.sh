DEPLOY_DATA_HASH=$(sha256sum hash_verified_install.sh | cut -d' ' -f1) && echo $DEPLOY_DATA_HASH
DEPLOY_DATA=$(gzip --best --stdout hash_verified_install.sh | base64 --wrap=0) && echo $DEPLOY_DATA