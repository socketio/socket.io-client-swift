import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';

// Fresh, short-lived localhost-only PKI for each test process. Keys never enter
// the repository or the OS trust store. Real TLS tests use the current clock.
const directory = resolve(process.argv[2] ?? '');
if (!process.argv[2]) throw new Error('A temporary output directory is required');
mkdirSync(directory, { recursive: true, mode: 0o700 });
const config = `
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = SocketIO temporary test CA
[ v3_ca ]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[ ca ]
default_ca = local_ca
[ local_ca ]
database = ${join(directory, 'index')}
new_certs_dir = ${directory}
certificate = ${join(directory, 'ca.pem')}
private_key = ${join(directory, 'ca.key')}
serial = ${join(directory, 'serial')}
default_md = sha256
policy = names
unique_subject = no
[ names ]
commonName = supplied
[ server ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
[ client ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
`;
writeFileSync(join(directory, 'openssl.cnf'), config);
writeFileSync(join(directory, 'index'), '');
writeFileSync(join(directory, 'index.attr'), 'unique_subject = no\n');
writeFileSync(join(directory, 'serial'), '1000\n');
function openssl(...args) {
  const result = spawnSync('openssl', args, { cwd: directory, encoding: 'utf8', timeout: 15000 });
  if (result.error || result.status !== 0) {
    throw new Error(`openssl ${args.join(' ')}: ${result.error ?? result.stderr}`);
  }
}
openssl('req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '30',
        '-config', 'openssl.cnf', '-extensions', 'v3_ca', '-keyout', 'ca.key', '-out', 'ca.pem');
openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=localhost',
        '-keyout', 'leaf.key', '-out', 'leaf.csr');
const stamp = date => date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z').replace('T', '');
const now = Date.now();
openssl('ca', '-batch', '-notext', '-config', 'openssl.cnf', '-extensions', 'server',
        '-in', 'leaf.csr', '-out', 'leaf.pem', '-startdate', stamp(new Date(now - 3600000)),
        '-enddate', stamp(new Date(now + 7 * 86400000)));
openssl('ca', '-batch', '-notext', '-config', 'openssl.cnf', '-extensions', 'server',
        '-in', 'leaf.csr', '-out', 'expired.pem', '-startdate', '20200101000000Z',
        '-enddate', '20210101000000Z');
for (const name of ['ca', 'leaf', 'expired']) {
  openssl('x509', '-in', `${name}.pem`, '-outform', 'DER', '-out', `${name}.der`);
}

openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=SocketIO test client',
        '-keyout', 'client.key', '-out', 'client.csr');
openssl('ca', '-batch', '-notext', '-config', 'openssl.cnf', '-extensions', 'client',
        '-in', 'client.csr', '-out', 'client.pem', '-startdate', stamp(new Date(now - 3600000)),
        '-enddate', stamp(new Date(now + 7 * 86400000)));
// Explicit portable PKCS#12 algorithms supported by Apple Security as well as OpenSSL 3.
openssl('pkcs12', '-export', '-inkey', 'client.key', '-in', 'client.pem',
        '-out', 'client.p12', '-passout', 'pass:fixture', '-keypbe', 'PBE-SHA1-3DES',
        '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1');
