#!/bin/sh

# When we get killed, kill all our children
trap "exit" INT TERM
trap "kill 0" EXIT

# Source in util.sh so we can have our nice tools
. $(cd $(dirname $0); pwd)/util.sh

# Immediately run auto_enable_configs so that nginx is in a runnable state
auto_enable_configs

# Start up nginx, save PID so we can reload config inside of run_certbot.sh
nginx -g "daemon off;" &
export NGINX_PID=$!

# Lastly, run startup scripts
for f in /scripts/startup/*.sh; do
    if [ -x "$f" ]; then
        echo "Running startup script $f"
        $f
    fi
done


# generate three tier certificate chain

SUBJ="/C=$COUNTY/ST=$STATE/L=$LOCATION/O=$ORGANISATION"

if [ ! -f "$CERT_DIR/$ROOT_NAME.crt" ]
then
  # generate root certificate
  ROOT_SUBJ="$SUBJ/CN=$ROOT_CN"

  echo " ---> Generate Root CA private key"
  openssl genrsa \
    -out "$CERT_DIR/$ROOT_NAME.key" \
    "$RSA_KEY_NUMBITS"

  echo " ---> Generate Root CA certificate request"
  openssl req \
    -new \
    -key "$CERT_DIR/$ROOT_NAME.key" \
    -out "$CERT_DIR/$ROOT_NAME.csr" \
    -subj "$ROOT_SUBJ"

  echo " ---> Generate self-signed Root CA certificate"
  openssl req \
    -x509 \
    -key "$CERT_DIR/$ROOT_NAME.key" \
    -in "$CERT_DIR/$ROOT_NAME.csr" \
    -out "$CERT_DIR/$ROOT_NAME.crt" \
    -days "$DAYS"
else
  echo "ENTRYPOINT: $ROOT_NAME.crt already exists"
fi

if [ ! -f "$CERT_DIR/$ISSUER_NAME.crt" ]
then
  # generate issuer certificate
  ISSUER_SUBJ="$SUBJ/CN=$ISSUER_CN"

  echo " ---> Generate Issuer private key"
  openssl genrsa \
    -out "$CERT_DIR/$ISSUER_NAME.key" \
    "$RSA_KEY_NUMBITS"

  echo " ---> Generate Issuer certificate request"
  openssl req \
    -new \
    -key "$CERT_DIR/$ISSUER_NAME.key" \
    -out "$CERT_DIR/$ISSUER_NAME.csr" \
    -subj "$ISSUER_SUBJ"

  echo " ---> Generate Issuer certificate"
  openssl x509 \
    -req \
    -in "$CERT_DIR/$ISSUER_NAME.csr" \
    -CA "$CERT_DIR/$ROOT_NAME.crt" \
    -CAkey "$CERT_DIR/$ROOT_NAME.key" \
    -out "$CERT_DIR/$ISSUER_NAME.crt" \
    -CAcreateserial \
    -extfile issuer.ext \
    -days "$DAYS"
else
  echo "ENTRYPOINT: $ISSUER_NAME.crt already exists"
fi

if [ ! -f "$CERT_DIR/$PUBLIC_NAME.key" ]
then
  # generate public rsa key
  echo " ---> Generate private key"
  openssl genrsa \
    -out "$CERT_DIR/$PUBLIC_NAME.key" \
    "$RSA_KEY_NUMBITS"
else
  echo "ENTRYPOINT: $PUBLIC_NAME.key already exists"
fi

if [ ! -f "$CERT_DIR/$PUBLIC_NAME.crt" ]
then
  # generate public certificate
  echo " ---> Generate public certificate request"
  PUBLIC_SUBJ="$SUBJ/CN=$PUBLIC_CN"
  openssl req \
    -new \
    -key "$CERT_DIR/$PUBLIC_NAME.key" \
    -out "$CERT_DIR/$PUBLIC_NAME.csr" \
    -subj "$PUBLIC_SUBJ"

  # append public cn to subject alt names
  echo "DNS.1 = $PUBLIC_CN" >> public.ext

  echo " ---> Generate public certificate signed by $ISSUER_CN"
  openssl x509 \
    -req \
    -in "$CERT_DIR/$PUBLIC_NAME.csr" \
    -CA "$CERT_DIR/$ISSUER_NAME.crt" \
    -CAkey "$CERT_DIR/$ISSUER_NAME.key" \
    -out "$CERT_DIR/$PUBLIC_NAME.crt" \
    -CAcreateserial \
    -extfile public.ext \
    -days "$DAYS"
else
  echo "ENTRYPOINT: $PUBLIC_NAME.crt already exists"
fi

if [ ! -f "$CERT_DIR/ca.pem" ]
then
  # make combined root and issuer ca.pem
  echo " ---> Generate a combined root and issuer ca.pem"
  cat "$CERT_DIR/$ISSUER_NAME.crt" "$CERT_DIR/$ROOT_NAME.crt" > "$CERT_DIR/ca.pem"
else
  echo "ENTRYPOINT: ca.pem already exists"
fi

if [ ! -f "$CERT_DIR/$KEYSTORE_NAME.pfx" ]
then
  # make PKCS12 keystore
  echo " ---> Generate $KEYSTORE_NAME.pfx"
  openssl pkcs12 \
    -export \
    -in "$CERT_DIR/$PUBLIC_NAME.crt" \
    -inkey "$CERT_DIR/$PUBLIC_NAME.key" \
    -certfile "$CERT_DIR/ca.pem" \
    -password "pass:$KEYSTORE_PASS" \
    -out "$CERT_DIR/$KEYSTORE_NAME.pfx"
else
  echo "ENTRYPOINT: $KEYSTORE_NAME.pfx already exists"
fi

echo "Done with startup"

# Instead of trying to run `cron` or something like that, just sleep and run `certbot`.
while [ true ]; do
    echo "Run certbot"
    /scripts/run_certbot.sh

    # Sleep for 1 week
    sleep 604810 &
    SLEEP_PID=$!

    # Wait on sleep so that when we get ctrl-c'ed it kills everything due to our trap
    wait "$SLEEP_PID"
done
