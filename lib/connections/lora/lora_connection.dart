/*
 * LoRa — a slot for a radio that does not exist yet.
 *
 * Read by `_LoraBearer` in xprs_publisher.dart, which asks one question:
 * whether a LoRa radio is present this second. It answers no, and will until
 * there is hardware to answer for.
 *
 * ── Why this is not a `Connection` any more ─────────────────────────────────
 *
 * It used to extend a `Connection` base class registered in a
 * `ConnectionRegistry` at boot. That registry was a capability catalogue with
 * no `send` method, four of five entries wrapping no implementation, no entry
 * for Reticulum — the primary transport — and `bluetooth`/`lan` reporting
 * `unavailable` while both were carrying live traffic. Nothing read it: one
 * string in a boot-task description was the only reference outside its own
 * directory. An inventory that is wrong is worse than no inventory, so it went.
 *
 * What was worth keeping from it is the vocabulary — bandwidth, payload, reach,
 * delivery mode — and that lives on `XprsBearer`, which is the abstraction that
 * actually carries packets and the one the airtime budget prices.
 */

/// Whether a LoRa radio is attached and usable.
enum LoraStatus { available, unavailable }

class LoraConnection {
  const LoraConnection();

  /// No radio code yet, so the honest answer is `unavailable`. `_LoraBearer`
  /// reports `inactive` on the strength of it rather than pretending a lane
  /// exists — a bearer that claims to be up and refuses every frame is the
  /// failure mode this avoids.
  LoraStatus get status => LoraStatus.unavailable;
}
