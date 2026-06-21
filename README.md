# Swarmarchy ISO

The Swarmarchy ISO streamlines [the installation of Swarmarchy](https://learn.omacom.io/2/the-swarmarchy-manual/50/getting-started). It includes the Swarmarchy Configurator as a front-end to archinstall and automatically launches the [Swarmarchy Installer](https://github.com/basecamp/omarchy) after base arch has been setup.

## Downloading the latest ISO

See the ISO link on [omarchy.org](https://omarchy.org).

## Creating the ISO

Run `./bin/swarmarchy-iso-make` and the output goes into `./release`. You can build from your local $SWARMARCHY_PATH for testing by using `--local-source` or from a checkout of the dev branch (instead of master) by using `--dev`.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `SWARMARCHY_INSTALLER_REPO` - GitHub repository for the installer (default: `basecamp/omarchy`)
- `SWARMARCHY_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `master`)

Example usage:
```bash
SWARMARCHY_INSTALLER_REPO="myuser/swarmarchy-fork" SWARMARCHY_INSTALLER_REF="some-feature" ./bin/swarmarchy-iso-make
```

## Testing the ISO

Run `./bin/swarmarchy-iso-boot [release/swarmarchy.iso]`.

## Signing the ISO

Run `./bin/swarmarchy-iso-sign [gpg-user] [release/swarmarchy.iso]`.

## Uploading the ISO

Run `./bin/swarmarchy-iso-upload [release/swarmarchy.iso]`. This requires you've configured rclone (use `rclone config`).

## Full release of the ISO

Run `./bin/swarmarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
