#!/bin/sh
# Create the stable Android release identity outside the repository, once.
set -eu
python3 - <<'PY'
import os, pathlib, secrets, subprocess
directory = pathlib.Path.home() / '.local/share/browser-android'
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
config = directory / 'release-signing.properties'
keystore = directory / 'release-signing.p12'
if config.exists() or keystore.exists():
    raise SystemExit('Signing identity already exists at ' + str(directory) + '; keeping it unchanged.')
password = secrets.token_urlsafe(48)
environment = os.environ.copy()
environment['BROWSER_KEY_PASSWORD'] = password
keytool = str(pathlib.Path(os.environ['JAVA_HOME']) / 'bin/keytool') if os.environ.get('JAVA_HOME') else 'keytool'
subprocess.run([keytool, '-genkeypair', '-keystore', str(keystore), '-storetype', 'PKCS12',
    '-alias', 'browser-android', '-keyalg', 'RSA', '-keysize', '4096', '-sigalg', 'SHA256withRSA',
    '-validity', '10000', '-dname', 'CN=Browser Android Release,O=Browser',
    '-storepass:env', 'BROWSER_KEY_PASSWORD', '-keypass:env', 'BROWSER_KEY_PASSWORD'], env=environment, check=True)
os.chmod(keystore, 0o600)
config.write_text('storeFile=' + str(keystore) + '\nstorePassword=' + password + '\nkeyAlias=browser-android\nkeyPassword=' + password + '\n')
os.chmod(config, 0o600)
print('Created release signing identity at ' + str(directory))
print('Back up both files securely. Future updates must use this identity.')
PY
