/*
 * lib/connections/ — the radios and the wires.
 *
 * What is here: the BLE5 stack and its GATT/MSP session lane (bluetooth/),
 * WiFi Direct, the host-side HTTP client, the LoRa slot, and the transport HAL
 * ABI wapps are given (hal/).
 *
 * ── What used to be here, and why it is not ─────────────────────────────────
 *
 * A `ConnectionRegistry` of `Connection` descriptors, populated at boot so
 * "wapps can reason about available connections". Nothing ever read it. The
 * base class had no `send`; four of its five entries wrapped no implementation;
 * Reticulum — the primary transport — had no entry at all; and `bluetooth` and
 * `lan` reported `unavailable` while both were carrying live traffic. A
 * catalogue that is wrong about the running system is worse than no catalogue,
 * because the first person to trust it is misled by it.
 *
 * The abstraction that does the job it was reaching for is `XprsBearer`
 * (services/xprs/xprs_publisher.dart): it has a real `send`, a live `active`
 * probe, the `scope:` predicate, and — since the airtime budget needed it — the
 * capability vocabulary the registry contributed. One transport abstraction,
 * and it is the one packets actually go through.
 */

export 'internet/http_transport.dart';
export 'lora/lora_connection.dart';
