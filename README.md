# emissary

**Authenticated execution over Nostr.** An emissary is a key that acts for the
principals on its allowlist. Requests reach it over three transports, and every one
carries a sender the transport *authenticated*:

| transport | the sender is |
|---|---|
| NIP-17 private messages (NIP-59 gift wraps) | the key that signed the seal |
| [Marmot](https://github.com/marmot-protocol/marmot) groups (MLS over Nostr) | the message's MLS sender |
| [FIPS](https://learn.fips.network) DataPackets | the static key the FSP session authenticated |

A request from a principal goes to the **handler**, and the answer goes back the way
the request came. Anyone else gets silence and a log line: an emissary does not
confirm it exists to strangers. One key serves every transport, so one allowlist
entry covers a person everywhere.

The default handler evaluates the request as Lisp in a **fresh, killable
[modus](https://github.com/modus-lisp/modus) process**, restored from a saved core in
about 25 ms: it is stopped at a deadline, a crash in it is its own, `*read-eval*` is
off, and nothing one request defines is visible to the next. Any other function of a
request can be the handler -- an LLM agent loop, say.

## ⚠️ Status

New, unaudited research software. The sandbox isolates *state* between requests,
not *capability*: a principal's form runs with whatever access the modus process has
(files, network). Only list principals you would hand a shell. No warranty (see
[LICENSE](LICENSE)).

## Use

```lisp
(asdf:load-system "emissary")
(defvar *e* (emissary:make-emissary :dir "~/.emissary/"
                                    :relays '("wss://relay.damus.io" "wss://nos.lol")
                                    :allow '("npub1..." "alice@example.com")))
(emissary:emissary-start *e*)                     ; DMs
(asdf:load-system "cl-marmot")
(emissary:attach-marmot *e* '("wss://relay.damus.io"))   ; Marmot groups
(asdf:load-system "cl-fips/daemon")
(emissary:attach-fips *e* :udp "0.0.0.0:2121")            ; FIPS, port 4601
(emissary:emissary-run *e*)
```

`DIR` holds the emissary's key (`emissary.key`, made on first use), its principals
(`allow.txt`: one npub, hex key or NIP-05 address per line, `#` comments), the DM
watermark and the sandbox core. Principals can also be added with `ALLOW`.

A handler is a function of a `REQUEST` (`REQUEST-TRANSPORT`, `REQUEST-SENDER`,
`REQUEST-TEXT`, `REQUEST-CREATED`) returning the reply text, or NIL for none:

```lisp
(emissary:make-emissary :handler (lambda (r) (string-upcase (emissary:request-text r))) ...)
```

`SEND-DM` messages a principal unprompted. `EMISSARY-STEP` runs one turn, for a
caller with its own loop.

## Design

**One thread drives it.** `EMISSARY-STEP` pumps the relays (cl-nostr's `PUMP`), steps
the other transports, then handles what came in. On modus that is required -- a
connection belongs to the thread that drives it, and a thread's objects cannot be
stored where another can reach them -- and on SBCL, where cl-nostr's relay threads
deliver, the queue they deliver into is locked.

**DMs** keep operandi's behaviour: a rumor stamped before the *floor* (the newest one
answered last time, persisted in `dm.state`) is not answered after a restart; the
emissary publishes its kind-10050 DM relay list and adds each principal's (and a
NIP-05 principal's relay hints); a long reply is split at natural boundaries into
numbered messages kept in order. Only kind-14 rumors are requests -- a Marmot Welcome
is a kind-444 rumor in a wrap to the same key.

**Marmot** uses the emissary's key for its account, so the same npub is invited to
groups. Anyone may invite it; only principals' messages are handled.

**FIPS** runs a node under the emissary's key. A request must fit one datagram; a
reply is cut to `*FIPS-MAX-REPLY*` bytes.

## Dependencies

[cl-nostr](https://github.com/modus-lisp/cl-nostr) (and through it natrium,
secp256k1-fast, seal, json-simple) and bordeaux-threads. Optional:
[cl-marmot](https://github.com/modus-lisp/cl-marmot),
[cl-fips](https://github.com/modus-lisp/cl-fips). The default handler needs a `modus`
binary (`*MODUS-BINARY*`, or `$MODUS_BIN`).

## Tests

```sh
sbcl --script test/unit.lisp                   # no network: chunking, principals, dispatch
test/run-giftwrap.sh /path/to/modus            # DMs, against a throwaway `nak serve` relay
test/run-marmot.sh   /path/to/modus            # a Marmot group an SBCL cl-marmot client creates
test/run-fips.sh     /path/to/modus            # an SBCL cl-fips node dials the emissary
test/run-all.sh      /path/to/modus            # one emissary, all three at once
EMISSARY_LISP=sbcl test/run-giftwrap.sh /path/to/modus   # the emissary itself on SBCL
```

The end-to-end scripts need [nak](https://github.com/fiatjaf/nak) and run the emissary
on modus (children are always modus) against SBCL clients. `test/deps.lisp` finds the
modus-lisp libraries in `$MODUS_LISP` or beside this checkout, and third-party systems
through Quicklisp, or in the subdirectories of `$EMISSARY_EXTRA` (colon-separated) on
modus. A stranger check passes only if the emissary *logged a refusal* of the
stranger's request: "no reply" alone also happens when the request never arrived.
