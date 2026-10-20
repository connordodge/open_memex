/// Which vault is open (D12): a local folder or a vault on a vault server.
sealed class VaultRef {
  const VaultRef();
}

/// A local vault: the folder holding `manifest.json` and `memex.db`.
final class LocalVaultRef extends VaultRef {
  const LocalVaultRef(this.path);

  final String path;
}

/// A hosted vault: [vaultName] on the vault server [serverId].
final class HostedVaultRef extends VaultRef {
  const HostedVaultRef(this.serverId, this.vaultName);

  final String serverId;
  final String vaultName;
}
