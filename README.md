# Elecrow Home Assistant Dial

The M5Dial Home Assistant interface ported to the Elecrow 1.28-inch ESP32-S3
rotary display. The original 240x240 layouts, fonts, images, carousels and page
animations are retained. Hardware wiring comes from the working Elecrow config.

## Configuration

Use [example_entry.yaml](example_entry.yaml) as the local device configuration
in Home Assistant ESPHome. It imports this repository from GitHub; you do not
need a local copy of `src/` or the assets.

1. Publish the package changes to the Git revision the local entry imports.
   Remote imports cannot see unpublished workspace changes.
2. Set the local device name, friendly name, entity IDs and light bindings.
3. Keep `wifi_ssid` and `wifi_password` in your existing local secrets file.
4. Replace the example's public dummy API encryption key, OTA password and
   fallback hotspot password before flashing. The dummy values are only for
   validation, not secure deployment. Real values can also use local `!secret`
   references; remote packages do not perform secret lookups.
5. Run ESPHome Validate, build and your normal OTA installation.

If earlier example credentials were real and have been published, rotate them;
removing them from the current file does not remove them from Git history.

The public package is [dial.yaml](dial.yaml).
[elecrow-dial.yaml](elecrow-dial.yaml) remains a compatibility wrapper for older
package imports. Import one or the other, not both. Neither is a standalone
device configuration: the local entry supplies identity and connectivity.

The shared package owns the ESP32/PSRAM settings, pins, hardware boot actions,
pages, idle initialization and HA connection callbacks. Do not repeat these in
the local entry. Its local API encryption settings merge with the shared HA
callbacks. Wi-Fi/AP, OTA and captive portal belong to the local entry.

Override `timezone`, `weather_entity`, `aqi_entity`, `climate_entity`,
`music_player_entity`, `timer_entity` and the `screen_*` substitutions locally.
Shared defaults contain no personal entity IDs. Clock defaults to
`America/Chicago`; optional Climate, Music and Timer menu items stay hidden
until their placeholder entity IDs are replaced. Weather/AQI can show missing
data placeholders. Timer remains hidden while `timer_entity` is
`timer.your_timer`.

Enable **Allow the device to perform Home Assistant actions** in the ESPHome
integration's device options so light, climate and music commands can run.

## Configuring Lights

Lights default to an empty list and the Lights menu is hidden. The example
configures seven lights using explicit `dial_lights` bindings. Each light also
needs one instance of the remote
[sensor template](src/main/dial_lights_sensors.yaml), with a unique
`light_sensor_prefix` and its `light_entity_id`. The template creates four text
and four numeric sensors; it does not add the light to the menu automatically.

For example, this is the one-light portion of a local entry. Keep the device
identity and connectivity sections from the full example alongside it:

```yaml
substitutions:
  package_ref: main
  asset_ref: ${package_ref}
  light_entity: light.living_room_light_group

dial_lights:
  - entity_id: light.living_room_light_group
    name: Living Room
    state_sensor: dial_light_living_room_state
    modes_sensor: dial_light_living_room_modes
    brightness_sensor: dial_light_living_room_brightness
    color_sensor: dial_light_living_room_rgb
    color_mode_sensor: dial_light_living_room_color_mode
    color_temp_kelvin_sensor: dial_light_living_room_color_temp_kelvin
    min_color_temp_kelvin_sensor: dial_light_living_room_min_color_temp_kelvin
    max_color_temp_kelvin_sensor: dial_light_living_room_max_color_temp_kelvin

packages:
  smart_home_button:
    url: https://github.com/emackinnon1/elecrow-dial
    ref: ${package_ref}
    files:
      - dial.yaml
      - path: src/main/dial_lights_sensors.yaml
        vars:
          light_entity_id: light.living_room_light_group
          light_sensor_prefix: living_room
    refresh: 0s
```

To add a light, add both its explicit `dial_lights` entry and a template
instance. IDs follow `dial_light_<prefix>_<suffix>`; keep all eight bindings
matched to that prefix and entity. To remove a light, remove both parts.
For no lights, omit the template instances and `dial_lights` entirely, or set
`dial_lights: []`. `light_entity` is a legacy fallback; set it to a configured
light when using lights. A group and its individual members may intentionally
appear as separate choices.

## Assets and Revisions

Static images and the music icon font download from this repository at build
time, then embed in the firmware. Google Fonts and pinned external components
also download during the build. The device does not fetch these static UI
assets at runtime; SendSpin artwork remains a separate runtime feature.

The example uses `package_ref: main` for both the remote package and its
`asset_ref`, including all per-light template imports in the same package.
Set `package_ref` to a published commit or tag for reproducible builds. When
writing a different entry, keep the package/template refs and `asset_ref`
aligned explicitly: a Git package ref does not automatically set an asset ref.

`assets_base_url` can override the asset host; by default it is
`https://raw.githubusercontent.com/emackinnon1/elecrow-dial/${asset_ref}/src/assets`.
Downloads are cached by ESPHome. `refresh: 0s` requests package updates on each
configuration/build while following a branch; use a published immutable ref
for a stable installation.

## Hardware and Behavior

The adapter is [src/main/hardware.yaml](src/main/hardware.yaml).

| Component | Elecrow Configuration |
| --- | --- |
| GC9A01A display | MOSI11, CLK10, CS9, DC3, RESET14; existing inversion/rotation |
| CST816 touch | SDA6, SCL7, IRQ5, RESET13; existing coordinate transform |
| Encoder | GPIO45/GPIO42, pull-ups, resolution 1 |
| Press button | GPIO41; original electrical configuration retained |
| Backlight | LEDC GPIO46, `display_backlight` |
| Other outputs | GPIO40/4/12/1/2; existing boot behavior retained |

GPIO46 is the Elecrow backlight, not the M5 battery power-hold output. No M5
power-hold, NFC, RTC or buzzer configuration is included.

- Clock: HA time, refreshed immediately on sync and every minute. After cold
  boot it shows placeholders until synchronized. Time continues while powered
  after a sync; there is no battery-backed timekeeping.
- Navigation: rotate to adjust/select, short press to accept, double press for
  Back, and horizontal touch gestures. Input actions use the source scripts;
  the encoder/button are not additionally registered as LVGL focus inputs.
- Climate: HA-native target values, minimum/maximum and `target_temp_step`.
  Missing step defaults to 1 degree. Temperature actions wait for valid target
  and range data. The entity must expose a single `temperature` setpoint;
  dual-setpoint thermostat support is not added by this port.
- Weather: pressure/wind labels use the corresponding HA unit attributes;
  unknown units show placeholders rather than incorrect metric labels.
- Idle: dim after 45 seconds, return to menu after 5 minutes, backlight off
  after 30 minutes. Dim level is 20%. These defaults are substitutions.
  Return-to-menu preserves the actual source implementation, whose README
  describes return-to-clock instead. First input after DIM/OFF only wakes.
- Music: original SendSpin components and artwork placeholder retained.
  HA controls target the selected media player; live art still requires a
  compatible SendSpin source. No local speaker/audio output is configured.
- Timer: when enabled, finish feedback remains visual and wakes the display;
  timer, climate and music beeps are omitted.

`encoder_control_steps` starts at `1` for light-selector and climate actions,
matching the Elecrow's existing resolution. Tune it only after measuring steps
per physical detent. Other page controls retain their source handlers.

## Validate and Install

Use your existing Home Assistant ESPHome Validate/build/OTA workflow. No local
build environment or firmware flash is part of this change. The source pins
ESPHome 2026.7.0 in its requirements; compatibility with your installed version
still needs ESPHome validation and a successful build. Initial builds download
the external components, images and fonts.

The static package checks use Ruby's standard library and Minitest:

```sh
/usr/bin/ruby tests/package_contract_test.rb
```

They check YAML keys, configuration ownership, wrapper includes, dummy key
format, revision alignment, zero/one/seven-light bindings and asset sources.
The seven-light example has 56 sensor bindings. These checks do not run
ESPHome's package loader/schema validator, compile firmware or prove a remote
import works. A generic YAML extension may flag ESPHome's valid `!secret` and
`!lambda` tags.

After publishing, validate the actual remote entry in a clean HA ESPHome
configuration directory containing only the local entry and its Wi-Fi secrets,
with no `src/` directory. Confirm device identity, local substitutions, one set
of boot actions and one OTA entry survive merging. Validate zero-light and
one-light configurations as well; check the compatibility wrapper separately
if it is used. Do not report a local include test as a successful remote import.

After validation and your OTA upload, check:

1. Loading/menu/clock/lights/climate/music render with the expected orientation,
   colors, layout and clipping; no test card appears.
2. Touch coordinates and left/right swipes work. Button idle/pressed polarity,
   single/double clicks and encoder direction/step size behave correctly.
   Pressing the screen must not cause an unintended touch-plus-button action.
3. All configured lights show HA state/capabilities and control the correct entities;
   group/member changes refresh. Climate and music actions round-trip to HA.
4. Clock synchronizes in Chicago time, weather units match HA, and SendSpin
   safely falls back to its placeholder without a compatible source.
5. Dim/return/off stages work; the entire first touch/turn/press only wakes,
   brightness restores, and no competing old timeout turns off the screen.
6. Reconnection and missing entities behave sensibly. Check the build's RAM,
   flash/OTA size and device logs for resets. Timer tests are deferred until a
   real helper is configured; test start/pause/resume/cancel/finish then.

The original configuration is preserved at
[backups/elecrow-dial.yaml.original](backups/elecrow-dial.yaml.original).
It is not an extra ESPHome device YAML. Retain it until hardware testing is done.

## Source and Attribution

UI adapted from [emackinnon1/m5stack-dial-home-assistant](https://github.com/emackinnon1/m5stack-dial-home-assistant),
local source snapshot `f91d805463dc1f7b086e372dc8d48f3e5fbd3144`.
That project derives from hectorzin's M5Dial controller and Jasionf's Smart Home
Button. The original project was not modified.

External components are pinned to:

- `dial_lights`, `dial_carousel`: `4d7c49c45713a4a145336a5c8dbb95d42c7f7fb5`
  from `fix/light_entity_fixes`, using the explicit sensor-binding interface.
- `generic_image`, `media_source`, `sendspin`:
  `c0d6a0bd8401486ca1fa7ad3ae3bfbcaff036b94`, as in the source music page.

See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for
the original attribution and third-party asset notices.