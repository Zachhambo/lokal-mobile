# Discord mobile SDK 1.10.19337

`discord-mobile-1.10.19337.zip.gpg` is an AES-256 encrypted archive of the three
SDK files supplied by the application owner: `include/discordpp.h`,
`lib/release/discord_partner_sdk.aar` and `License-Notices.txt`.

The encrypted archive is retained for optional local development only. Signed
Android release builds intentionally do not decrypt or stage it. To opt in to
local Rich Presence development, use `python3 tool/prepare_discord_sdk.py`
with the passphrase in a local environment, then follow
`docs/DISCORD_PRESENCE.md`. Plaintext staging is ignored by Git.
