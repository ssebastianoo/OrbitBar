# OrbitBar image proxy

A Cloudflare Worker that fetches images from other sites for OrbitBar, so a task description can't learn your IP
address or make your Mac send requests into your local network. Images on your Orbit server never go through it: the
app fetches those directly, with your session.

```sh
cd worker/image-proxy
npm install
npx wrangler login
npx wrangler deploy            # → https://orbitbar-image-proxy.<your-subdomain>.workers.dev
npx wrangler secret put PROXY_KEY   # optional
```

Then give the URL (and the key, if you set one) to the app build through the environment. They are not committed:

```sh
export ORBITBAR_IMAGE_PROXY=https://orbitbar-image-proxy.<your-subdomain>.workers.dev
export ORBITBAR_IMAGE_PROXY_KEY=…   # optional
scripts/build-app.sh
```

For the release workflow, add the GitHub secrets `ORBITBAR_IMAGE_PROXY` and, optionally, `ORBITBAR_IMAGE_PROXY_KEY`
(`gh secret set ORBITBAR_IMAGE_PROXY`). `scripts/build-app.sh` writes them into the app's Info.plist as
`OrbitBarImageProxy` and `OrbitBarImageProxyKey`.

Without a URL, images from other sites show a "Load Image" button instead of loading on their own.
