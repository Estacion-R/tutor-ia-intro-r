/**
 * Apps Script web app para persistir el log del Tutor de R en su Google Sheet.
 *
 * Por qué: la org de Estación R bloquea descargar claves de service account
 * (iam.disableServiceAccountKeyCreation), así que en vez de que la app escriba
 * la Sheet con una SA, este script (pegado a la Sheet) recibe los eventos por
 * POST y los appendea. No hay credencial de larga duración; un token compartido
 * valida cada POST.
 *
 * DEPLOY (una vez):
 *   1. Abrí la Sheet de logs → Extensiones → Apps Script.
 *   2. Pegá este código. Reemplazá TOKEN por un secreto random (ej. salida de
 *      `openssl rand -hex 16`). Ese mismo valor va en la env var
 *      TUTOR_LOG_TOKEN de Connect Cloud.
 *   3. Implementar → Nueva implementación → tipo "Aplicación web".
 *        - Ejecutar como: Yo
 *        - Quién tiene acceso: Cualquier usuario
 *      Implementar → autorizá los permisos → copiá la "URL de la aplicación web".
 *      Esa URL va en la env var TUTOR_LOG_WEBHOOK_URL de Connect Cloud.
 *   4. En Connect Cloud: setear TUTOR_LOG_WEBHOOK_URL + TUTOR_LOG_TOKEN y Republish.
 *
 * Si cambiás el código, "Administrar implementaciones" → editar → Nueva versión
 * (la URL se mantiene).
 */

const TOKEN = 'PEGA_ACA_UN_TOKEN_SECRETO'; // debe coincidir con TUTOR_LOG_TOKEN
const COLS = ['ts', 'type', 'email', 'session_id', 'provider', 'categoria',
              'pide_respuesta', 'input_chars', 'response_chars', 'details'];

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    if (!body || body.token !== TOKEN) {
      return _json({ ok: false, error: 'unauthorized' });
    }
    const ev = body.event || {};
    const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
    const row = COLS.map(function (c) {
      const v = ev[c];
      return (v === undefined || v === null) ? '' : v;
    });
    sheet.appendRow(row);
    return _json({ ok: true });
  } catch (err) {
    return _json({ ok: false, error: String(err) });
  }
}

function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
