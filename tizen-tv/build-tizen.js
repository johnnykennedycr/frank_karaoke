const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');

const TIZEN_DIR = __dirname;
const ROOT_DIR = path.dirname(TIZEN_DIR);
const DIST_DIR = path.join(ROOT_DIR, 'dist');
const STAGE_DIR = path.join(DIST_DIR, 'tizen-stage');
const FINAL_WGT = path.join(DIST_DIR, 'FrankKaraoke.wgt');

const LOCAL_WEBIDE_MODULE = 'C:\\Users\\Johnny\\Dev\\Moon-sun\\builder\\node_modules\\@tizentv\\webide-common-tizentv';
const LOCAL_CERT_PROFILE_DIR = path.join(DIST_DIR, 'cert-profile');
const LOCAL_APPS2SAMSUNG_CLI = 'C:\\Users\\Johnny\\Dev\\Moon-sun\\installer\\cli\\apps2samsung-cli.exe';

function copyDirSync(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    if (entry.name === 'build-tizen.js' || entry.name.endsWith('.wgt')) continue;
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirSync(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

async function buildWithTizenSdk() {
  const { TVWebApp, TizenCertManager, ProfileManager } = require(LOCAL_WEBIDE_MODULE);
  fs.mkdirSync(LOCAL_CERT_PROFILE_DIR, { recursive: true });

  const certMgr = new TizenCertManager(LOCAL_CERT_PROFILE_DIR);
  await certMgr.init();

  const profileMgr = new ProfileManager(LOCAL_CERT_PROFILE_DIR);
  const authorCertPath = path.resolve(LOCAL_CERT_PROFILE_DIR, 'Author', 'frankkaraoke.p12');

  if (!fs.existsSync(authorCertPath)) {
    certMgr.createCert({
      keyFileName: 'frankkaraoke',
      authorName: 'FrankKaraoke',
      authorPassword: 'password123',
      countryInfo: 'BR',
      stateInfo: 'SP',
      cityInfo: 'SP',
      organizationInfo: 'FrankKaraoke',
      departmentInfo: 'Dev',
      emailInfo: 'frank@karaoke.lan'
    });
  }

  const authorProfile = {
    authorCA: certMgr.getTizenDeveloperCA(),
    authorCertPath,
    authorPassword: 'password123'
  };
  const distributorProfile = {
    distributorCA: 'C:\\tizentv-tools\\certificate-generator\\certificates\\distributor\\sdk-public\\tizen-distributor-ca-new.cer',
    distributorCertPath: 'C:\\tizentv-tools\\certificate-generator\\certificates\\distributor\\sdk-public\\tizen-distributor-signer-new.p12',
    distributorPassword: 'tizenpkcs12passfordsigner'
  };

  await profileMgr.registerProfile('FrankKaraokeProfile', authorProfile, distributorProfile);
  profileMgr.setActivateProfile('FrankKaraokeProfile');

  const app = new TVWebApp('FrankKaraokeTV', STAGE_DIR, 'FrnkKaraok');
  await app.buildWidget(profileMgr.profilePath);

  const generatedWgt = path.join(STAGE_DIR, 'FrankKaraokeTV.wgt');
  if (fs.existsSync(generatedWgt)) {
    fs.copyFileSync(generatedWgt, FINAL_WGT);
    console.log(`[Build] Signed Tizen package created: ${FINAL_WGT}`);
    return true;
  }
  return false;
}

function buildUnsignedZipFallback() {
  console.log('[Build] Packaging Tizen .wgt archive...');
  if (fs.existsSync(FINAL_WGT)) fs.unlinkSync(FINAL_WGT);
  const tempZip = path.join(DIST_DIR, 'FrankKaraoke.zip');
  if (fs.existsSync(tempZip)) fs.unlinkSync(tempZip);

  if (process.platform === 'win32') {
    execSync(`powershell -NoProfile -Command "Compress-Archive -Path '${STAGE_DIR}\\*' -DestinationPath '${tempZip}' -Force"`);
  } else {
    execSync(`cd "${STAGE_DIR}" && zip -r "${tempZip}" .`);
  }
  fs.renameSync(tempZip, FINAL_WGT);
  console.log(`[Build] Created Tizen .wgt package: ${FINAL_WGT}`);
}

async function main() {
  if (fs.existsSync(STAGE_DIR)) {
    fs.rmSync(STAGE_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(DIST_DIR, { recursive: true });
  copyDirSync(TIZEN_DIR, STAGE_DIR);

  if (fs.existsSync(LOCAL_WEBIDE_MODULE) && fs.existsSync('C:\\tizentv-tools')) {
    await buildWithTizenSdk();
  } else {
    buildUnsignedZipFallback();
  }

  // Also copy FrankKaraoke.wgt into tizen-tv/ so it can be tracked or downloaded easily
  const repoWgt = path.join(TIZEN_DIR, 'FrankKaraoke.wgt');
  fs.copyFileSync(FINAL_WGT, repoWgt);

  const tvIpIndex = process.argv.indexOf('--tv');
  const tvIp = tvIpIndex !== -1 ? process.argv[tvIpIndex + 1] : null;

  if (tvIp && fs.existsSync(LOCAL_APPS2SAMSUNG_CLI)) {
    console.log(`[Install] Installing and launching FrankKaraoke.wgt on Samsung TV (${tvIp})...`);
    execFileSync(LOCAL_APPS2SAMSUNG_CLI, ['install', FINAL_WGT, '--tv', tvIp, '--partner', '--yes'], { stdio: 'inherit' });
    console.log(`[Install] Successfully installed & launched Frank Karaoke TV on ${tvIp}!`);
  }
}

main().catch(err => {
  console.error('[Error]', err);
  process.exit(1);
});
