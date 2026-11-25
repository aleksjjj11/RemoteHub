/// Peer option holding the host display the owner chose for a device: the
/// name the host reports, never an index. Written natively before each
/// connect (`remote_hub::apply_viewer_preferences`).
const kRemoteHubOptionDisplay = 'remote-hub-display';

/// Which host display the viewer selects for a saved preference.
class DisplayChoice {
  const DisplayChoice(this.index, {this.missing = false});

  /// Index into the host's current display list, or null to keep the
  /// host's choice.
  final int? index;

  /// A display was saved but the host does not report it now; the owner is
  /// told that another display is shown (plan 11.6).
  final bool missing;
}

/// The display named [preferred] among the host's [names] (in host order).
/// An empty [preferred] keeps the host's choice.
DisplayChoice chooseRemoteHubDisplay(List<String> names, String preferred) {
  if (preferred.isEmpty) return const DisplayChoice(null);
  final i = names.indexOf(preferred);
  return i < 0 ? const DisplayChoice(null, missing: true) : DisplayChoice(i);
}
