export function readTlsOptions(bundle: string | undefined):
  | { cert: string; key: string; passphrase: string }
  | undefined {
  if (!bundle) return undefined;

  const value: unknown = JSON.parse(bundle);
  if (!value || typeof value !== 'object') throw new Error('Invalid TLS bundle');
  const { certificate, privateKey, passphrase } = value as Record<string, unknown>;
  if (typeof certificate !== 'string' || typeof privateKey !== 'string' ||
      typeof passphrase !== 'string' || !certificate || !privateKey || !passphrase) {
    throw new Error('Invalid TLS bundle');
  }
  return { cert: certificate, key: privateKey, passphrase };
}
