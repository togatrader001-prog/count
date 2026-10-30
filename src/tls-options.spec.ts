import { readTlsOptions } from './tls-options.js';

describe('TLS configuration', () => {
  it('keeps local development on HTTP when no bundle is configured', () => {
    expect(readTlsOptions(undefined)).toBeUndefined();
  });

  it('uses the certificate, encrypted key, and passphrase from the secret', () => {
    const bundle = JSON.stringify({ certificate: 'cert', privateKey: 'key', passphrase: 'pass' });
    expect(readTlsOptions(bundle)).toEqual({ cert: 'cert', key: 'key', passphrase: 'pass' });
  });

  it('fails closed when the TLS bundle is incomplete', () => {
    expect(() => readTlsOptions('{"certificate":"cert"}')).toThrow('Invalid TLS bundle');
  });
});
