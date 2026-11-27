# Open questions

Each question has the default that the work follows until the owner answers.

## ztcl::vm images (ztcl#312)

- On Linux, `ztcl::vm image install DIR` opens DIR through the file jail, then reads the files by the path of `/proc/self/fd/N`. A symlink that the script swaps in the folder between the two steps could name a file outside the root folder, which the store then refuses unless its SHA-256 is in the signed manifest. Default: keep it, since a file must match the signed hash; a later change reads each file through the descriptor of the folder (`openat`).
- `image fetch` and `image update` download a release of GitHub over HTTPS. Default: `std.http.Client` of Zig with its TLS, behind the capability `socket` and the network policy of the embedder, with no new dependency.
