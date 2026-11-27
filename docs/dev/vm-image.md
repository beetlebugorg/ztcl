# Signed guest images of `ztcl::vm`

A guest image release (ztcl#312) is a set of files and a manifest that lists them, with an SSH signature of the manifest. ztcl checks the signature with a key that it has built in, then checks each file by its SHA-256 before a guest uses it. A read-only disk also has a `dm-verity` root hash in the manifest, which goes on the command line of the kernel, so a disk that changes after the check fails on read in the guest. Each host (Virtualization.framework, KVM, HCS) reads the same manifest. The code is `src/vmimage.zig`.

## The files of a release

```
manifest.json        the manifest below
manifest.json.sig    its SSH signature (ssh-keygen -Y sign -n ztcl-vm-image)
<arch>/Image ...     the kernel, the initramfs, and the disks of each architecture
```

## The manifest

JSON, with these fields. Hashes are lowercase hex.

```json
{
  "format": 1,
  "name": "ztcl-guest",
  "version": "0.1.0",
  "counter": 3,
  "min_ztcl": "0.1.0",
  "archs": {
    "arm64": {
      "kernel": {"file": "arm64/Image", "sha256": "…"},
      "initrd": {"file": "arm64/agent.cpio.gz", "sha256": "…"},
      "cmdline": "rdinit=/sbin/agent quiet",
      "disks": [
        {"name": "root", "file": "arm64/root.img", "sha256": "…", "size": 67108864, "read_only": true,
         "verity": {"root_hash": "…", "salt": "…", "data_block": 4096, "hash_block": 4096, "hash_offset": 67108864}}
      ]
    },
    "x86_64": {"kernel": {"file": "x86_64/bzImage", "sha256": "…"}, "cmdline": "…", "disks": []}
  }
}
```

| Field | Meaning |
|---|---|
| `format` | 1. Another value is refused. |
| `name`, `version` | The name and the version of the image, for people. |
| `counter` | A number that grows with each release. ztcl keeps the highest counter that it accepted and refuses a lower one (a rollback to an older image with a known flaw), unless the user forces it. |
| `min_ztcl` | The oldest ztcl that can run the image. |
| `archs` | `arm64` and `x86_64`: the kernel, the initramfs, the command line, and the disks of each. |
| `disks[].read_only` | A read-only disk has `verity`. A writable disk is a disk of one guest and is not in a release. |
| `disks[].verity` | The `dm-verity` parameters: the root hash, the salt, the block sizes, and the offset of the hash tree in the file. The host puts them on the command line of the kernel (`dm-mod.create=`). |

## The signature

`manifest.json.sig` is the SSHSIG form of OpenSSH (`PROTOCOL.sshsig`), armored between `-----BEGIN SSH SIGNATURE-----` and `-----END SSH SIGNATURE-----`. ztcl takes only an Ed25519 key, the hash `sha512`, and the namespace `ztcl-vm-image`. A signature with another namespace, another key, or a change of one byte of the manifest is refused. Anyone can check a release with OpenSSH alone:

```sh
echo "ztcl-vm-image ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOXmjXPwM3MICS/d9Zh3EkyW8hvvXWXkpcudKf4W0lYE" > allowed
ssh-keygen -Y verify -f allowed -I ztcl-vm-image -n ztcl-vm-image -s manifest.json.sig < manifest.json
```

## The keys

| Key | Fingerprint | Where its private half is |
|---|---|---|
| current | `SHA256:UiBcvO9PN2dsGQx6x+Ua0+mvp1Y9EFJ/orEdoQ80OFE` | The secret `VM_IMAGE_SIGNING_KEY` (with `VM_IMAGE_SIGNING_PASSPHRASE`) of the GitHub environment `vm-release`. |
| next | `SHA256:xAXpwepaYOIzgKdeDV37kkLIHXoiq1UcU6Va6MRIHVI` | Offline, with the owner of the repository. It signs nothing until a rotation. |
| test | `SHA256:0i6ppbGLTgfdCV7fHFHBcnyT2S3mnECDbJ3BMwSUJO4` | `tools/vm-guest/testkey`, in the repository. Only a test build, or a build with `-Dvm-test-key`, trusts it. |

ztcl trusts current and next. A test of the fingerprints in `src/vmimage.zig` checks that the keys in the code are these.

The private half of the test key is in the repository, so anyone can sign with it. The guards:

- Only a test build (`zig build test`) or a Debug build with `-Dvm-test-key` trusts it. `build.zig` refuses `-Dvm-test-key` with each Release mode, so a release build or a package of the release and npm workflows cannot trust it.
- The test key signs only a manifest whose `name` ends in `-test`. A manifest with the name of a release image, such as `ztcl-guest`, signed by the test key is refused as untrusted. An SSH signature names one key, so a manifest is either signed by a release key or by the test key, never both.
- A build that trusts the test key prints a warning on stderr when `ztcl::vm` starts, and `ztcl::vm image verify` (step 3) will name the key of each check.

## Signing in CI

The workflow of the image (`.github/workflows/vm-guest.yml`) builds each architecture on a runner of its own (`build.sh`, `pack.sh`, `image.sh`), then signs the manifest of both (`manifest.sh`) with the test key, under the name `ztcl-guest-test`, on each pull request that changes the guest. On a tag `vm-image-vVERSION`, or a run by hand from `main`, the job `manifest-release` in the environment `vm-release` signs the manifest under the name `ztcl-guest` with the current key (`tools/vm-guest/keys/current.pub`): it writes the key to a file of mode 0600, adds it to an `ssh-agent` of the job with an askpass script that gives the passphrase from the environment, signs through the agent, then ends the agent and erases the files. It checks the signature with ztcl itself before it uploads `manifest.json.sig`. The first run with the current key waits on the owner.

## The build

`image.sh` makes the read-only root disk of each architecture: a squashfs of BusyBox and the agent, padded to whole 4 KiB blocks, then the `dm-verity` hash tree after the data (`veritysetup format --no-superblock`, with a salt that comes from the name of the architecture). The command line of the manifest boots it with no initramfs:

```
init=/sbin/agent root=/dev/dm-0 rootfstype=squashfs ro dm-mod.waitfor=/dev/vda
dm-mod.create="root,,,ro,0 SECTORS verity 1 /dev/vda /dev/vda 4096 4096 BLOCKS BLOCKS sha256 ROOT_HASH SALT"
```

The disk is the first virtio-blk disk of the guest (`/dev/vda`), read-only. A block that does not match the tree gives an error of read in the guest. The build is reproducible: the kernel and BusyBox get a fixed time, user, and host (`SOURCE_DATE_EPOCH`, `KBUILD_BUILD_*`), and squashfs gets fixed times and owners. The log of `image.sh` prints the SHA-256 of the kernel and of the disk, and the root hash, of each architecture.

## The store

`src/vmstore.zig` keeps the images of a user: `objects/SHA256` for each file, `releases/NAME/COUNTER/` with the manifest and its signature, and `releases/NAME/current` and `highest`. A file comes in under `tmp/`, is checked against the manifest, and moves to `objects/` with a rename; the release folder and then `current` change with a rename too, so an update is atomic and a running guest keeps its files. Each step works through a descriptor: the release through the descriptor of its folder that the file jail opened, and the store through the descriptor of its own folder, each name opened with `O_NOFOLLOW`. A symlink in the release or in the store is an error, so a path that changes after a check cannot lead outside. `ztcl::vm image install|list|verify|remove` and `ztcl::vm create -image` use it (`docs/modules/vm.md`).

## A rotation

When the current key may be known to someone else (a leak of the secret, or a compromise of a workflow or of the repository):

1. A ztcl release drops current from `release_keys` and trusts only next. The users update ztcl.
2. The owner makes a new key pair for the place of next, and puts the old next key (the new current) in the secret of `vm-release`.
3. The next ztcl release has the new current and the new next. Each image after it is signed with the new current, with a higher counter.

A planned rotation, with no compromise, is the same with step 1 and step 3 in one release.
