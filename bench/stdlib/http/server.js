// The TechEmpower plaintext and JSON tests in Node.js: node server.js PORT
// SPDX-License-Identifier: BSD-2-Clause
const http = require("http");
http.createServer((req, res) => {
  if (req.url === "/plaintext") {
    res.writeHead(200, { "Content-Type": "text/plain", Server: "node" });
    res.end("Hello, World!");
  } else if (req.url === "/json") {
    res.writeHead(200, { "Content-Type": "application/json", Server: "node" });
    res.end(JSON.stringify({ message: "Hello, World!" }));
  } else {
    res.writeHead(404);
    res.end();
  }
}).listen(Number(process.argv[2]), "127.0.0.1");
