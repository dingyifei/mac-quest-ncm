# ALVR / wine-vr over the USB link

The ALVR v20.14.1 server (embedded in wine-vr's oxrsys core) **connects to the client**:
- TCP 9943 for control, 9944 for the stream;
- the client listens on IPv4 `0.0.0.0`.

So pinning the Quest's link address is enough. Discovery broadcasts don't cross the link, so pin by IP.

1. `mqncm up` (add `sudo mqncm share on` if you want UDP streaming; see step 6).
2. Stop the core: `./demo.sh stop --bottle <bottle>` in wine-vr.
3. Back up, then edit `~/Library/Application Support/OXRSys/alvr/session.json` **while the core is stopped**:
   ```sh
   cp ~/Library/Application\ Support/OXRSys/alvr/session.json{,.bak-ncm}
   python3 - <<'PY'
   import json, os
   p = os.path.expanduser('~/Library/Application Support/OXRSys/alvr/session.json')
   s = json.load(open(p)); cc = s['client_connections']
   cc.pop('client.wired', None)              # otherwise ALVR re-creates adb forwards and connects over 127.0.0.1
   for v in cc.values(): v['manual_ips'] = []
   cc['quest.ncm'] = {'display_name': 'Quest (NCM)', 'current_ip': None,
                      'manual_ips': ['192.168.42.2'], 'trusted': True, 'connection_state': 'Disconnected'}
   c = s['session_settings']['connection']
   c['stream_protocol'] = {'variant': 'Tcp'}  # UDP only after `share on` (see step 6)
   c['client_discovery']['enabled'] = False
   json.dump(s, open(p, 'w'), indent=2)
   PY
   ```
4. Make sure `adb forward --list` shows no 9943/9944 forwards. Then start wine-vr **from Terminal.app** without `--wired`. Terminal is exempt from Local Network privacy; GUI-launched CrossOver may need the Local Network permission.
5. Launch the ALVR client on the Quest. Verify with:
   ```sh
   lsof -nP -iTCP:9943 -iTCP:9944 | grep ESTABLISHED   # peers 192.168.42.2
   mqncm monitor                                        # traffic on the link interface
   ```
6. **UDP:** with the cable as the Quest's default network (`share on`, or Quest Wi‑Fi off), set `stream_protocol` back to `{"variant": "Udp"}`. Without that, the Quest sends its UDP replies over Wi‑Fi.

**Do not use ALVR's dashboard API at `127.0.0.1:8082`.** Other software (e.g. OrbStack) may hold that exact address; ALVR binds `*:8082`. Use `http://192.168.42.1:8082` if you need the live API.

**Restore:** stop the core and copy `session.json.bak-ncm` back.
