# Bundled fonts

The app's three type families, bundled so google_fonts loads them from the
asset bundle and never fetches at run time (#373, Spec #367 requirement 18).
`configureFonts()` in `lib/src/theme/font_setup.dart` turns runtime fetching
off and registers each family's licence with `LicenseRegistry`.

Each file is named the way google_fonts looks it up in the asset manifest,
`<FamilyNoSpaces>-<Variant>.ttf`. The set is every weight and style the
`OmType` functions in `lib/src/theme/typography.dart` can ask for:

| Family | Used by | Files | Font version | Licence |
|---|---|---|---|---|
| Inter Tight | `OmType.sans` | Thin to Black (100-900), normal | 3.004 | `OFL-InterTight.txt` |
| JetBrains Mono | `OmType.mono` | Thin to ExtraBold (100-800), normal | 2.211 | `OFL-JetBrainsMono.txt` |
| Newsreader | `OmType.serif` | ExtraLight to ExtraBold (200-800), normal and italic | 1.003 (16pt optical size) | `OFL-Newsreader.txt` |

All three are licensed under the SIL Open Font License, Version 1.1, which
allows bundling and redistribution with the licence text.

## Source

- **Fonts:** the static instances Google Fonts serves, the same bytes
  google_fonts 6.3.3 fetched before they were bundled:
  `https://fonts.gstatic.com/s/a/<sha256>.ttf`, with the SHA-256 and length
  google_fonts lists in `lib/src/google_fonts_parts/part_{i,j,n}.g.dart`.
  Each file's SHA-256 below was checked against that list.
- **Licences:** `OFL.txt` from the google/fonts repository
  (`https://github.com/google/fonts`, `ofl/intertight/`, `ofl/jetbrainsmono/`,
  `ofl/newsreader/`), unchanged.

Upstream projects: Inter Tight (https://github.com/rsms/inter-tight),
JetBrains Mono (https://github.com/JetBrains/JetBrainsMono), Newsreader
(https://github.com/productiontype/Newsreader).

## Updating

To bump a family, take the new hashes from the google_fonts version the app
depends on, download each `https://fonts.gstatic.com/s/a/<sha256>.ttf` under
the name in the table below, check its SHA-256, and update this file.

| File | SHA-256 |
|---|---|
| InterTight-Thin.ttf | e7ffae93eaccdc071f195b2ee0e003519a551c80449ad508aca0bb3262b7d260 |
| InterTight-ExtraLight.ttf | 404cf43ed675c94c12ca0699a8b0e8132d2568f0b0e6447947b2791baebb0f48 |
| InterTight-Light.ttf | dc26a04f1025b93c048c01a4b68c4926d1fffb5fffd33942d77449cb305f0b09 |
| InterTight-Regular.ttf | d09b8f0d43ec915a1e498032fe7aaf881398894d747b4cefa2f4c0fea9daaf3d |
| InterTight-Medium.ttf | af87cb250f2aa0ef59ab6d84897bc1e14bee4e226ec367c6535a041aacbd406d |
| InterTight-SemiBold.ttf | 762c775d505b2500346fddfcfbe912b4579d39a2df74f04fd226312ec04ba200 |
| InterTight-Bold.ttf | a6d3bb37d0a595f5452ae34e774865633a53e265c0f6b40f64721624d3adebe3 |
| InterTight-ExtraBold.ttf | 309f9d518f9c443c9cbc3dd7998a1a90a1abc410e7176c702af930c11739822e |
| InterTight-Black.ttf | 2853ea2d892129f4b1a67469a6af18366ac29593869ff9f69d25040a2ae8c76f |
| JetBrainsMono-Thin.ttf | 9a44b1b4adc03c445877e325d57d0879cb22840ff640a40e6515be59c845b015 |
| JetBrainsMono-ExtraLight.ttf | 9133ef0d504f0d80e5478902ee49e8f815ade6f5621fc89c5d6b9263549325d7 |
| JetBrainsMono-Light.ttf | 0623d0562debca9e5d97996af1de5e98f672a20f2ee6085cec86cd6a77ec3595 |
| JetBrainsMono-Regular.ttf | fc34426314d00825ccc768a0c4b1178fe704f04bd947882ef10c2b71b7e355e7 |
| JetBrainsMono-Medium.ttf | ba10286722bd7dc2274b817575046e39ee816d6ba1e2ace48e22bcd068576941 |
| JetBrainsMono-SemiBold.ttf | f833596d98e0e021dd43d993254658d0f32318f82f08afee0fc2e41c16ce9571 |
| JetBrainsMono-Bold.ttf | b43a7dfebfb8816fb3859f6a7932824f594e115538ccd3f1ebc0ffc231b0acab |
| JetBrainsMono-ExtraBold.ttf | 98ea78a2337e1ef2274f247c857a63e40e975c6907a7baff9209033fa42142ac |
| Newsreader-ExtraLight.ttf | 1046c7a061e009f88fdc58791969f5999cf31174e8cd8d5c4044f437a07550aa |
| Newsreader-Light.ttf | 09cdb18a68c56dac91d53f4bb4f80853376cdebecb912f8c20d31e36c383f50b |
| Newsreader-Regular.ttf | e57916a6608d8319d2fe2aab76131086c6cf889fe9f144e5909059ae5d2a963a |
| Newsreader-Medium.ttf | bfc5844dd702a7374bfbca74707d70823b329f324b8f730d2f1e0ac0920df1d8 |
| Newsreader-SemiBold.ttf | 46af64a6a049bd0d33cf96a3b390bb10cb4c049028a067e25880dccd3c7deb85 |
| Newsreader-Bold.ttf | 8b39f0339b03b1c534ff30ac3aa287a61d4f49e2f6650526e33b569c52361f10 |
| Newsreader-ExtraBold.ttf | 041885013d27657ee7820f809b4812063daa0217849bacb86ecc4d7cfa070b66 |
| Newsreader-ExtraLightItalic.ttf | bbdf1e49155c2e55b8bbc64a703bb3cf4a40a2167df4130d9ec4538bb46f7517 |
| Newsreader-LightItalic.ttf | 8e4023919880a8ff057054cebe1d9fdd20f8ce0895684131d01eca7e024e786f |
| Newsreader-Italic.ttf | 2af40965b6aceec5194321f5a98f14136fb13d954d7829ac0c698faeb5c7fbc7 |
| Newsreader-MediumItalic.ttf | 8e1f4bfe64000b51af417a84a9b9499d8b0bb435cf7473495c49430978c3296a |
| Newsreader-SemiBoldItalic.ttf | 77b44dcda98f17b2225d04bebb68aa1793afa06122c4487eeb691122d4fdf03b |
| Newsreader-BoldItalic.ttf | eb77219e34fa811cc6ef094bb1e72ab69177b6c87587048ed8f469cae3bc9132 |
| Newsreader-ExtraBoldItalic.ttf | 6d90dc45e45b5be72f9aab43df3e449e89a416c12fcbd0f976370dbb82f7102d |
