# infrahub-console (Vercel)

`https://infrahub-console.vercel.app` forwards every path to the Infra Hub
Center console served from the laptop over the fixed ngrok domain
(`dipping-sympathy-stadium.ngrok-free.dev`). The console itself can't run on
Vercel: live logs, the SSH console and agent connections are WebSockets to
the API, which Vercel can't proxy. Change `destination` in `vercel.json`
when the console moves to a permanent server, then run `vercel deploy --prod`
from this folder.
