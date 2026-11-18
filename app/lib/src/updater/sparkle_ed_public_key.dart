/// The base64 Ed25519 public key Self-update verifies every download against
/// (Spec #31 req 21, D9). Empty means no key: every install is refused.
///
/// A build may supply it with `--dart-define=SPARKLE_ED_PUBLIC_KEY=<key>`;
/// otherwise it is the committed key.
const sparkleEdPublicKey = String.fromEnvironment(
  'SPARKLE_ED_PUBLIC_KEY',
  defaultValue: _committed,
);

/// The committed release public key. Empty until the release key lands.
const _committed = '';
