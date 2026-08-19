# kod.dev

The Kod website is a dependency-free static site deployed to GitHub Pages by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml). It makes no
runtime requests except when a visitor follows a link, and it uses no
analytics, cookies, local storage, external fonts, or client-side JavaScript.
The preview gallery images are captures of Kod's production `PreviewUI`
controllers rendered with safe, checked-in repository files.

## Build locally

The build script stages the site under the ignored `Artifacts/` directory,
copies the app icon from the Xcode asset catalog, and injects direct download
links from a published release:

```sh
KOD_ARM64_DOWNLOAD_URL='https://github.com/friggeri/kod/releases/download/v1.0.0/Kod-1.0.0-arm64.dmg' \
KOD_X86_64_DOWNLOAD_URL='https://github.com/friggeri/kod/releases/download/v1.0.0/Kod-1.0.0-x86_64.dmg' \
KOD_RELEASE_TAG='v1.0.0' \
Scripts/build-website
```

Serve `Artifacts/website/` with any local static file server.

Run the dependency-free artifact checks with:

```sh
Scripts/verify-website
```

## Release contract

The latest published GitHub release must contain exactly one asset matching
`Kod-*-arm64.dmg` and exactly one matching `Kod-*-x86_64.dmg`. The Pages
workflow resolves their `browser_download_url` values and injects them into the
generated HTML. Before the first matching release exists, pushes validate the
site but deliberately skip deployment.

## GitHub Pages and domain setup

1. In **Settings → Pages** for `friggeri/kod`, select **GitHub Actions** as the
   publishing source.
2. Verify `kod.dev` in the `friggeri` GitHub account before changing DNS.
3. In the repository's Pages settings, set the custom domain to `kod.dev`.
   Custom Actions workflows configure the domain through repository settings;
   a `CNAME` file in the uploaded artifact is ignored by GitHub Pages.
4. At the DNS provider, add these apex `A` records:

   ```text
   185.199.108.153
   185.199.109.153
   185.199.110.153
   185.199.111.153
   ```

5. Add these optional IPv6 `AAAA` records:

   ```text
   2606:50c0:8000::153
   2606:50c0:8001::153
   2606:50c0:8002::153
   2606:50c0:8003::153
   ```

6. Add a `www` CNAME pointing directly to `friggeri.github.io` so GitHub can
   redirect `www.kod.dev` to the canonical apex domain.
7. After DNS resolves, enable **Enforce HTTPS** in Pages settings.

Do not add wildcard DNS records for the domain.
