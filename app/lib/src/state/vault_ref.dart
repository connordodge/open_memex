/// Which vault is open (D12): a local folder or a vault on a vault server.
/// Both kinds compare by value.
sealed class VaultRef {
  const VaultRef();
}

/// A local vault: the folder holding `manifest.json` and `memex.db`.
final class LocalVaultRef extends VaultRef {
  const LocalVaultRef(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is LocalVaultRef && other.path == path;

  @override
  int get hashCode => Object.hash(LocalVaultRef, path);

  @override
  String toString() => 'LocalVaultRef($path)';
}

/// A hosted vault: [vaultName] on the vault server [serverId].
final class HostedVaultRef extends VaultRef {
  const HostedVaultRef(this.serverId, this.vaultName);

  final String serverId;
  final String vaultName;

  @override
  bool operator ==(Object other) =>
      other is HostedVaultRef &&
      other.serverId == serverId &&
      other.vaultName == vaultName;

  @override
  int get hashCode => Object.hash(HostedVaultRef, serverId, vaultName);

  @override
  String toString() => 'HostedVaultRef($serverId, $vaultName)';
}

/// The folder behind a vault ref, for the sites that run the `memex` CLI on
/// the open vault or read files in it.
extension VaultRefLocalPath on VaultRef? {
  /// The folder of a [LocalVaultRef]. Null for a [HostedVaultRef] and for no
  /// vault, so a hosted vault takes each site's "no vault path" branch.
  String? get localPath => switch (this) {
    LocalVaultRef(:final path) => path,
    HostedVaultRef() || null => null,
  };
}
