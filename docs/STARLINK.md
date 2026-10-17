# Starlink Ethernet access and snow melt

Still a bit to test here. 

I want to keep antenna power consumption predictable without risking the station's
only internet connection. TELE therefore reads the antenna in normal operation;
changes to its settings require a separate explicit action.

## What can be done locally

The community-documented local gRPC interface uses `192.168.100.1:9200` and the
`SpaceX.API.Device.Device/Handle` service; configuration reads and attempted writes
are documented, including permission-denied responses for writes
([local API investigation](https://github.com/rcastellotti/idp/blob/main/starlink-grpc.md)).
The published protobuf schema defines `AUTO=0`, `ALWAYS_ON=1`, `ALWAYS_OFF=2`
and the `apply_snow_melt_mode` field
([DishConfig schema](https://github.com/clarkzjw/starlink-grpc-golang/blob/master/proto/spacex_api/device/dish_config.proto)).

That does not establish write permission on every dish or firmware. A maintainer report found local setting writes denied and observed the app communicating with
a remote HTTPS service instead; that is an older observation, not proof that every current firmware behaves identically
([snow-melt issue and investigation](https://github.com/sparky8512/starlink-grpc-tools/issues/48)).

The supported configuration route is the Starlink app: Settings → Starlink → Snow Melt → Off. Starlink describes Off as disabling Snow Melt and its extra
power use ([Starlink help](https://starlink.com/en-ps/support/article/123263fe-abc5-60e0-3af1-9e022aeba80a)).
This does not turn the antenna off or eliminate its normal operating power draw.

## Read over Ethernet

On the Ubuntu station, first inspect the route and read the setting:

```bash
# Run on Ubuntu station. Inspection only.
ip route get 192.168.100.1
/opt/tele/current/scripts/STARLINK.sh snow-melt
/opt/tele/current/scripts/STARLINK.sh status
```

The helper expects `grpcurl` and `jq`, installed by `INSTALL.sh`. The default address can be overridden explicitly, for example:

```bash
STARLINK_ADDRESS=192.168.100.1:9200 /opt/tele/current/scripts/STARLINK.sh config
```

If internet access works but this local address is unreachable, inspect the Ethernet/router topology. Do not add a guessed default route or reboot/reset the
antenna remotely: the installer deliberately leaves routing untouched.

The equivalent bounded read request is:

```bash
grpcurl -plaintext -emit-defaults -max-time 20 \
  -d '{"dish_get_config":{}}' \
  192.168.100.1:9200 SpaceX.API.Device.Device/Handle
```

`-emit-defaults` matters because an omitted enum value must not be mistaken for
proof that heating is Off. TELE accepts known numeric/string modes and reports
missing or unknown fields as a failure to verify.

## Optional attempt to turn it off

Only make this change if Off is appropriate for the site. Consider snow and ice obstruction risk, especially at the Antarctic station, before prioritizing the
power saving.

```bash
# Changes the setting if the local firmware permits it; requires explicit confirmation.
/opt/tele/current/scripts/STARLINK.sh snow-melt-off --confirm
```

The helper reads first. If already Off, it makes no write; otherwise it requests:

```json
{"dish_set_config":{"dish_config":{"snow_melt_mode":"ALWAYS_OFF","apply_snow_melt_mode":true}}}
```

It then requires a fresh read showing `ALWAYS_OFF`. A successful transport call
alone is not success, and `PermissionDenied`, a response error or unchanged mode
returns failure. No authentication bypass, Wi-Fi changes, stow, factory reset or
antenna reboot is attempted.

For installation, `STARLINK_SNOW_MELT=read` is the default. `off` in the private
setup bundle explicitly authorizes this attempt and sets
`STARLINK_EXPECT_SNOW_OFF=yes` in node.conf; subsequent collection runs read the
setting and report a mismatch rather than silently changing it.

## Persistence and acceptance test

I cannot promise that Ethernet can make this setting permanently immutable. The cited app instructions explain the available modes but do not establish a
guarantee across every future reset or firmware update ([Starlink setting instructions](https://starlink.com/en-ps/support/article/123263fe-abc5-60e0-3af1-9e022aeba80a)).

Set Off through the app if the local write is refused, verify readback on the
bench, power-cycle the actual computer/relay/antenna, and verify again after
connectivity returns. Keep checking after firmware changes, and review the
station's captured Starlink configuration alongside its weekly logs.

No live antenna was available for the automated tests. They cover parsing,
already-Off behaviour, denied writes and false-success rejection using mocked
responses; they do not establish hardware or firmware compatibility.
