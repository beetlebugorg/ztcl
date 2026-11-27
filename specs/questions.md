# Open questions

Each question has the default that the work follows until the owner answers.

## ztcl::vm images (ztcl#312)

- (Answered: close it.) `ztcl::vm image install DIR` reads the release through the descriptor of DIR that the jail opened, and the store works through the descriptor of its folder, each name with `O_NOFOLLOW`, so a symlink swapped in after the check of the jail is refused.
- `image fetch` and `image update` download a release of GitHub over HTTPS. Answered: `std.http.Client` of Zig for now, behind the capability `socket` and the network policy of the embedder; it moves to the TLS 1.3 of `src/tls` when that lands.
