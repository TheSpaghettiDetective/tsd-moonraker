import logging
import re
import time
from urllib.parse import urlparse
from moonraker_obico.webcam_capture import capture_jpeg
_logger = logging.getLogger('obico.nozzlecam')

class NozzleCamConfig:
    def __init__(self, snapshot_url):
        self.snapshot_url = snapshot_url
        self.snapshot_ssl_validation = False

class NozzleCam:

    def __init__(self, app_model, server_conn, moonrakerconn):
        self.model = app_model
        self.server_conn = server_conn
        self.moonrakerconn = moonrakerconn
        self.layer_change_macro_embedded_in_gcode = False
        self.last_on_first_layer = 0 # track the time the print was last on the first layer to give some buffer for macro to initiate first layer scanning

    def start(self):
        nozzle_config = self.create_nozzlecam_config()

        if nozzle_config is None:
            return

        capturing = False
        capturing_interval = 1 # 1s
        while True:
            time.sleep(capturing_interval)

            if not self.should_capture():
                if capturing:
                    self.notify_server_nozzlecam_complete()

                capturing = False
                capturing_interval = 1
                continue

            capturing = True
            try:
                self.send_nozzlecam_jpeg(capture_jpeg(nozzle_config))
            except Exception:
                _logger.error('Failed to capture and send nozzle cam jpeg', exc_info=True)

    def should_capture(self):
        if not self.model.printer_state.is_printing():
            self.layer_change_macro_embedded_in_gcode = False
            return False

        macro_status = self.first_layer_macro_status()
        macro_status_current_layer = macro_status.get('current_layer', -1)
        if macro_status_current_layer > 0: # _OBICO_LAYER_CHANGE is embedded in gcode
            self.layer_change_macro_embedded_in_gcode = True
            if macro_status_current_layer == 1:
                self.last_on_first_layer = time.time()
                return True
            elif macro_status_current_layer == 2:
                if macro_status.get('first_layer_scanning', False):
                    return True
                # 30s buffer for initiating scanning to avoid race condition: current_layer = 2 and first_layer_scanning = False
                return (time.time() - self.last_on_first_layer < 30)
            else:
                return False

        _, _, _, current_layer = self.model.printer_state.get_z_info()

        return current_layer == 1

    def first_layer_macro_status(self):
        return self.model.printer_state.status.get('gcode_macro _OBICO_LAYER_CHANGE', {})

    def send_nozzlecam_jpeg(self, snapshot):
        if snapshot:
                files = {'pic': snapshot}
                resp = self.server_conn.send_http_request('POST', '/ent/api/nozzle_cam/pic/', timeout=60, files=files, raise_exception=True, skip_debug_logging=True)
                _logger.debug('nozzle cam jpeg posted to server - {0}'.format(resp))

    def notify_server_nozzlecam_complete(self):
        try:
            data = {'nozzlecam_status': 'complete'}
            self.server_conn.send_http_request('POST', '/ent/api/nozzle_cam/first_layer_done/', timeout=60, data=data, raise_exception=True, skip_debug_logging=True)
            _logger.debug('server notified 1st layer is done')
        except Exception:
            _logger.error('Failed to send images', exc_info=True)

    def create_nozzlecam_config(self):
        try:
            ext_info = self.server_conn.send_http_request('GET', f'/ent/api/printers/{self.model.linked_printer["id"]}/ext/', timeout=60, raise_exception=True)
            _logger.debug(ext_info.json())
            nozzle_url = ext_info.json()['ext'].get('nozzlecam_url', '')
            if nozzle_url is None or len(nozzle_url) == 0:
                return None

            self.moonrakerconn.initialize_layer_change_macro(first_layer_scan_feedrate=600, first_layer_scan_enabled=True)

            return NozzleCamConfig(nozzle_url)
        except Exception:
            _logger.warn('Exception in build nozzle config. First Layer AI disabled.')
            return None
