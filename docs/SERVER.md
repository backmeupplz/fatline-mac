# Running a server

Fatline has no built-in server, so anyone can run one. The app builds the feed and signs every message on the Mac, so a server only forwards reads and already-signed messages. There are two kinds:

- [Custom server](#custom-server), entered under Advanced. It answers Neynar's feed routes and Snapchain's, and Fatline sends it no credential.
- [Invite server](#invite-server), entered under Use code. It hands out codes so other people can use it without an API key of their own.

## Custom server

Give your coding agent this guide: https://fatline.tech/custom-server.md. It deploys [fatline-server](https://github.com/danromero/fatline-server), checks it, and lists [what any other server has to answer](https://fatline.tech/custom-server.md#server-contract).

## Invite server

An invite lets someone use Fatline through your server, without an API key of their own. In the app, they choose Use code and enter it.

### The invite

An invite is one string, the code and then your server:

```
CODE@server.example
```

The server can include a port or a path, as in `CODE@server.example:8443/fatline`. Fatline only connects over HTTPS. A code is 1 to 128 characters from `A-Z a-z 0-9 - . _ ~`, and Fatline sends it exactly as it was entered.

### Requests

Every route below sits under `https://server.example/v1`, after any path in the invite. Each request carries the code:

```
X-Invite-Code: CODE
```

| Route | Parameters | Answer |
| --- | --- | --- |
| `GET /farcaster/feed/following/` | `fid`, `with_recasts=false`, `limit` from 1 to 100, optional `cursor` | Neynar's following feed: `casts`, and `next.cursor` |
| `GET /farcaster/user/bulk/` | `fids`, up to 100, separated by commas | Neynar's bulk users: `users` |
| `GET /node/castById` | `fid`, `hash` | Snapchain's answer |
| `GET /node/linksByFid` | `fid`, `link_type=follow`, optional `pageSize` and `pageToken` | Snapchain's answer |
| `GET /node/signersByFid` | `fid`, `pageSize` | Snapchain's answer |
| `GET /node/onChainIdRegistryEventByAddress` | `address` | Snapchain's answer |
| `GET /node/userDataByFid` | `fid`, `user_data_type=USER_DATA_TYPE_USERNAME` | Snapchain's answer |
| `POST /node/submitMessage` | Body: the signed message bytes, as `application/octet-stream` | Snapchain's answer |

The two feed routes end in a slash. `onChainIdRegistryEventByAddress` can take a node over 30 seconds for an unknown address, and Fatline waits up to 45.

Before saving an invite, Fatline reads `/farcaster/feed/following/?fid=1&with_recasts=false&limit=1` and expects a `casts` array, then `/node/userDataByFid?fid=1&user_data_type=USER_DATA_TYPE_USERNAME` and expects a `messages` array.

### Errors

Send errors as JSON with a `message`, which Fatline may show to the person:

```json
{ "message": "Too many messages. Try again in a minute." }
```

| Status | Meaning |
| --- | --- |
| `401` or `403` | The code is missing or wrong. |
| `402` | The code has used its allowance. Fatline keeps showing the posts it has. |
| `404` | The route doesn't exist, or a node has no such record. |
| `429` | Too many requests. |

If your own upstream key fails, answer `503` rather than passing along its `401`, `402`, or `403`, or Fatline will blame the person's code.

## What a server can see

A server sees which accounts someone reads and every signed message they post. It never receives their recovery phrase or posting key. It can still return false or missing data, so only connect to a server you trust.
