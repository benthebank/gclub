# G Club availability

A shared "which date works?" page for the club. Members open one link, tap their name and mark each
candidate date Free, Maybe or Can't. No accounts. The organiser sees the best dates, who has not replied,
and can lock in a date.

## Files

| File | What it is |
| --- | --- |
| `index.html` | The whole page (no build step). |
| `config.js` | Database address and publishable key. Safe to publish. |
| `supabase/schema.sql` | Tables and the five functions the page calls. |
| `.private/` | Holds the organiser key after setup. Never commit or publish it. |

## How it is protected

- The tables sit in a private schema the public API cannot read. The page can only call `gc_*` functions.
- Members can add or change a reply. Names are 1 to 40 characters, notes 280, only known dates and
  y / m / n are kept, and an event stops at 300 replies.
- Changing the gathering, locking a date or removing a reply needs the organiser key.
  Only its SHA-256 hash is stored.
- Anyone with the member link can overwrite a reply under the same name. This is a trust-your-friends poll.

## Organiser link

The organiser link is the member link plus `#admin=<key>`. Open it once on your device; the page
remembers you and removes the key from the address bar. To sign in on another device, use
"Organiser sign-in" at the bottom of the page and paste the link, or open the link there.
The part after `#` is never sent to any server.

## Deploying

1. Create a Supabase project and run `supabase/schema.sql`.
2. Insert the event row with the hash of your organiser key (never the key itself):
   `insert into gclub.events (id, admin_hash) values ('main', '<sha256 hex of key>');`
3. Put the project URL and publishable key in `config.js`.
4. Publish `index.html` and `config.js` on any static host (GitHub Pages, Netlify, Cloudflare Pages).
