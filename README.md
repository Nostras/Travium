# Travium — Travian T4.5 Private Server

A fast, stable Travian T4.5 clone with a one-click installer in a single command.

## Features

* 1-click automated install and configuration
* Works on fresh VMs/VPS, no prior setup required
* Opinionated, production-ready defaults
* CloudPanel integration for easy management and faster loading times
* Installer command generator: [https://init.travium.net/](https://init.travium.net/)

---

## Quick start

1. **Prepare a clean server**

   * Pick a supported OS (below), log in as `root`.
2. **Point DNS or hosts**

   * Set A records to your server IP (examples below).
3. **Run the installer**

   ```bash
   bash <(curl -skL https://init.travium.net/install.sh) \
       --domain example.com
   ```
4. **Finish setup**

   * Open the CloudPanel link shown at the end of the install.
   * Create a database.
   * Open the installer URL, fill details, click **Run Installer**.

> Prefer a prefilled command? Use the generator: [https://init.travium.net/](https://init.travium.net/)

> For me 

```bash
bash <(curl -skL https://raw.githubusercontent.com/Nostras/Travium/refs/heads/feature/wip/install.sh) --domain localtrav.test
```

> Re-using certificates

If you've run it already, you may just want to move your old certificates instead of regenerating (plus having to install it again sucks).

Pull it:
```bash
tar czf ~/certs-backup.tar.gz -C /etc/nginx/ssl-certificates \
  LOCALTRAV.key LOCALTRAV.crt LOCALTRAV.srl \
  localtrav.test.key localtrav.test.crt
```

Push it:
```bash
mkdir -p /root/certs-restore
tar xzf certs-backup.tar.gz -C /root/certs-restore

```

If you've already installed and just want to overwrite with old files, run the previous one +:
```bash
cp /root/certs-restore/* /etc/nginx/ssl-certificates/
chmod 600 /etc/nginx/ssl-certificates/LOCALTRAV.key /etc/nginx/ssl-certificates/localtrav.test.key
systemctl reload nginx
```

1 stop shop
```bash
bash <(curl -skL https://raw.githubusercontent.com/Nostras/Travium/refs/heads/feature/wip/install.sh) --domain localtrav.test
```

---

## Supported OS

* 🐧 Ubuntu 24.04 LTS
* 🐧 Ubuntu 22.04 LTS
* 🐧 Debian 13 LTS
* 🐧 Debian 12 LTS
* 🐧 Debian 11 LTS

> Important: Use a fresh machine.

---

## Requirements

* Clean VM/VPS with a supported OS
* Root access
* A domain you control
* Basic ability to copy-paste a command

---

## DNS / hosts setup

Point everything to your server IP. Replace `12.13.14.15` and `example.com`.

```
12.13.14.15 example.com www.example.com
12.13.14.15 server1.example.com server2.example.com     # add more game worlds as needed
12.13.14.15 api.example.com
12.13.14.15 cdn.example.com
12.13.14.15 install.example.com
12.13.14.15 voting.example.com
12.13.14.15 payment.example.com
```

If you’re just testing, you can use your local hosts file with the same lines.

---

## What the installer gives you

* CloudPanel ready to use
* Web vhosts, PHP, DB engine, and core services configured
* Game server scaffolding and routes
* Secure defaults and sensible limits

At the end you’ll see:

* **CloudPanel URL** and credentials
* **Installer URL** to finalize the game configuration

---

## Post-install checklist

1. Log in to **CloudPanel**
   Create a database:
   [https://www.cloudpanel.io/docs/v2/frontend-area/databases/](https://www.cloudpanel.io/docs/v2/frontend-area/databases/)

2. Visit the **Installer URL**
   Fill the form with your DB details, and any options you want.
   Click **Run Installer** and let it finish.

3. Open your domain and confirm the game is live.

---

## Dealing with certificates without cloudflare (yucky)

1. Find the certificates in `/etc/nginx/ssl-certificates`, this should contain a `.crt` and `.key` file.

2. Grab the `.crt` file and install it on your operating system.

## Contributing

* Fork, branch, commit
* Keep PRs focused and tested

---

## Credits

Core authors and contributors will be listed here.
If you shipped a fix or feature, you’ll get your shout-out.

---

## License

MIT
