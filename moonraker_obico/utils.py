from __future__ import absolute_import
from typing import Dict, Optional
import time
import re
import os
import random
import platform
import logging
import tempfile
from io import BytesIO
from urllib.error import URLError, HTTPError
import struct
import threading
import socket
from contextlib import closing
from typing import Union
from sarge import run, Capture
import backoff
import requests

import sentry_sdk
from sentry_sdk.integrations.threading import ThreadingIntegration
from sentry_sdk.integrations.logging import LoggingIntegration

from .version import VERSION

_logger = logging.getLogger('obico.utils')

DEBUG = os.environ.get('DEBUG')


class ExpoBackoff:

    def __init__(self, max_seconds, max_attempts=0):
        self.attempts = 0
        self.max_seconds = max_seconds
        self.max_attempts = max_attempts

    def reset(self):
        self.attempts = 0

    def more(self, e):
        self.attempts += 1
        if self.max_attempts > 0 and self.attempts > self.max_attempts:
            _logger.warning('Giving up after %d attempts on error: %s' % (self.attempts, e))
            raise e
        else:
            delay = 2 ** (self.attempts-3)
            if delay > self.max_seconds:
                delay = self.max_seconds
            delay *= 0.5 + random.random()
            _logger.info('Attempt %d - backing off %f seconds: %s' % (self.attempts, delay, e))

            time.sleep(delay)


class SentryWrapper:

    def __init__(self, config) -> None:
        self._enabled = (
            config.sentry_opt == 'in' and
            config.server.canonical_endpoint_prefix().endswith('app.obico.io')
        )

        if not self._enabled:
            return

        # https://github.com/getsentry/sentry-python/issues/149
        def before_send(event, hint):
            if 'exc_info' in hint:
                exc_type, exc_value, tb = hint['exc_info']
                errors_to_ignore = (URLError, HTTPError, requests.exceptions.RequestException,)
                if isinstance(exc_value, errors_to_ignore):
                    return None
            return event

        sentry_sdk.init(
            dsn='https://89fc4cf9318d46b1bfadc03c9d34577c@sentry.obico.io/8',
            default_integrations=False,
            integrations=[
                ThreadingIntegration(propagate_hub=True), # Make sure context are propagated to sub-threads.
                LoggingIntegration(
                    level=logging.INFO, # Capture info and above as breadcrumbs
                    event_level=None  # Send logs as events above a logging level, disabled it
                ),
            ],
            before_send=before_send,

            # If you wish to associate users to errors (assuming you are using
            # django.contrib.auth) you may enable sending PII data.
            send_default_pii=True,

            release='moonraker-obico@'+VERSION,
        )

        self.init_context(auth_token=config.server.auth_token)

    def enabled(self) -> bool:
        return self._enabled

    def init_context(self, auth_token: str) -> None:
        if self.enabled():
            sentry_sdk.set_user({'id': auth_token})
            for (k, v) in self.get_tags().items():
                sentry_sdk.set_tag(k, v)

    def captureException(self, *args, **kwargs) -> None:
        _logger.exception('')
        if self.enabled():
            sentry_sdk.capture_exception(*args, **kwargs)

    def captureMessage(self, *args, **kwargs) -> None:
        if self.enabled():
            sentry_sdk.capture_message(*args, **kwargs)

    def get_tags(self):
        (os, _, ver, _, arch, _) = platform.uname()
        tags = dict(os=os, os_ver=ver, arch=arch)
        try:
            v4l2 = run('v4l2-ctl --list-devices 2>/dev/null', stdout=Capture())
            v4l2_out = ''.join(re.compile(r"^([^\t]+)", re.MULTILINE).findall(v4l2.stdout.text)).replace('\n', '')
            if v4l2_out:
                tags['v4l2'] = v4l2_out
        except:
            pass

        try:
            usb = run("lsusb | cut -d ' ' -f 7- | grep -vE ' hub| Hub' | grep -v 'Standard Microsystems Corp'", stdout=Capture())
            usb_out = ''.join(usb.stdout.text).replace('\n', '')
            if usb_out:
                tags['usb'] = usb_out
        except:
            pass

        try:
            distro = run("cat /etc/os-release | grep PRETTY_NAME | sed s/PRETTY_NAME=//", stdout=Capture())
            distro_out = ''.join(distro.stdout.text).replace('"', '').replace('\n', '')
            if distro_out:
                tags['distro'] = distro_out
        except:
            pass

        try:
            long_bit = run("getconf LONG_BIT", stdout=Capture())
            long_bit_out = ''.join(long_bit.stdout.text).replace('\n', '')
            if long_bit_out:
                tags['long_bit'] = long_bit_out
        except:
            pass

        return tags


def get_image_info(data):
    data_bytes = data
    if not isinstance(data, str):
        data = data.decode('iso-8859-1')
    size = len(data)
    height = -1
    width = -1
    content_type = ''

    # handle GIFs
    if (size >= 10) and data[:6] in ('GIF87a', 'GIF89a'):
        # Check to see if content_type is correct
        content_type = 'image/gif'
        w, h = struct.unpack("<HH", data[6:10])
        width = int(w)
        height = int(h)

    # See PNG 2. Edition spec (http://www.w3.org/TR/PNG/)
    # Bytes 0-7 are below, 4-byte chunk length, then 'IHDR'
    # and finally the 4-byte width, height
    elif ((size >= 24) and data.startswith('\211PNG\r\n\032\n')
          and (data[12:16] == 'IHDR')):
        content_type = 'image/png'
        w, h = struct.unpack(">LL", data[16:24])
        width = int(w)
        height = int(h)

    # Maybe this is for an older PNG version.
    elif (size >= 16) and data.startswith('\211PNG\r\n\032\n'):
        # Check to see if we have the right content type
        content_type = 'image/png'
        w, h = struct.unpack(">LL", data[8:16])
        width = int(w)
        height = int(h)

    # handle JPEGs
    elif (size >= 2) and data.startswith('\377\330'):
        content_type = 'image/jpeg'
        jpeg = BytesIO(data_bytes)
        jpeg.read(2)
        b = jpeg.read(1)
        try:
            while (b and ord(b) != 0xDA):
                while (ord(b) != 0xFF):
                    b = jpeg.read(1)
                while (ord(b) == 0xFF):
                    b = jpeg.read(1)
                if (ord(b) >= 0xC0 and ord(b) <= 0xC3):
                    jpeg.read(3)
                    h, w = struct.unpack(">HH", jpeg.read(4))
                    break
                else:
                    jpeg.read(int(struct.unpack(">H", jpeg.read(2))[0])-2)
                b = jpeg.read(1)
            width = int(w)
            height = int(h)
        except struct.error:
            pass
        except ValueError:
            pass

    return content_type, width, height


def is_port_open(host, port):
    _logger.debug(f'Testing TCP port {port} on {host}')
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        return sock.connect_ex((host, port)) == 0


@backoff.on_exception(backoff.expo, Exception, max_tries=6, jitter=None)
@backoff.on_predicate(backoff.expo, max_tries=6, jitter=None)
def wait_for_port(host, port):
    return is_port_open(host, port)


def wait_for_port_to_close(host, port):
    for i in range(10):   # Wait for up to 5s
        with closing(
            socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ) as sock:
            if sock.connect_ex((host, port)) != 0:  # Port is not open
                return
            time.sleep(0.5)


def raise_for_status(resp, with_content=False, **kwargs):
    # puts reponse content into exception
    if with_content:
        try:
            resp.raise_for_status()
        except Exception as exc:
            args = exc.args
            if not args:
                arg0 = ''
            else:
                arg0 = args[0]
            arg0 = "{} {}".format(arg0, resp.text)
            exc.args = (arg0, ) + args[1:]
            exc.kwargs = kwargs

            raise
    resp.raise_for_status()


# Courtesy of https://github.com/OctoPrint/OctoPrint/blob/master/src/octoprint/util/__init__.py

def to_unicode(
    s_or_u: Union[str, bytes], encoding: str = "utf-8", errors: str = "strict"
) -> str:
    """
    Make sure ``s_or_u`` is a unicode string (str).
    Arguments:
        s_or_u (str or bytes): The value to convert
        encoding (str): encoding to use if necessary, see :meth:`python:bytes.decode`
        errors (str): error handling to use if necessary, see :meth:`python:bytes.decode`
    Returns:
        str: converted string.
    """
    if s_or_u is None:
        return s_or_u

    if not isinstance(s_or_u, (str, bytes)):
        s_or_u = str(s_or_u)

    if isinstance(s_or_u, bytes):
        return s_or_u.decode(encoding, errors=errors)
    else:
        return s_or_u


# Courtesy of https://github.com/OctoPrint/OctoPrint/blob/f430257d7072a83692fc2392c683ed8c97ae47b6/src/octoprint/util/files.py#L27

def sanitize_filename(name, really_universal=False):
    """
    Sanitizes the provided filename. Implementation differs between Python versions.
    Under normal operation, ``pathvalidate.sanitize_filename`` will be used, leaving the
    name as intact as possible while still being a legal file name under all operating
    systems.
    In all cases, a single leading ``.`` will be removed (as it denotes hidden files
    on *nix).
    Args:
        name:          The file name to sanitize. Only the name, no path elements.
    Returns:
        the sanitized file name
    """

    name = to_unicode(name)

    if name is None:
        return None

    if "/" in name or "\\" in name:
        raise ValueError("name must not contain / or \\")

    from pathvalidate import sanitize_filename as sfn
    result = sfn(name)
    return result.lstrip(".")


def pi_version():
    try:
        with open('/sys/firmware/devicetree/base/model', 'r') as firmware_model:
            model = re.search('Raspberry Pi(.*)', firmware_model.read()).group(1)
            if model:
                return "0" if re.search('Zero', model, re.IGNORECASE) else "3"
            else:
                return None
    except:
        return None


def os_bit():
    return platform.architecture()[0].replace("bit", "-bit")


def board_id():
    model_file = "/sys/firmware/devicetree/base/model"
    if os.path.isfile(model_file):
        with open(model_file, 'r') as file:
            data = file.read()
            if "raspberry" in data.lower():
                return "rpi"
            elif "makerbase" in data.lower() or "roc-rk3328-cc" in data:
                return "mks"
            elif data.lower().startswith("sun8i"):
                return "sun8i"
    return "NA"


def parse_integer_or_none(s):
    try:
        return int(s)
    except:
        return None


def run_in_thread(long_running_func, *args, **kwargs):
    daemon_thread = threading.Thread(target=long_running_func,  args=args, kwargs=kwargs)
    daemon_thread.daemon = True  # Setting the thread as daemon
    daemon_thread.start()
    return daemon_thread

def verify_link_code(config, code):
    endpoint_prefix = config.server.canonical_endpoint_prefix()
    url = f'{endpoint_prefix}/api/v1/octo/verify/'
    resp = requests.post(url, params={'code': code.strip()})
    _logger.debug(f'/api/v1/octo/verify/ responded: {resp}')

    if resp and resp.ok:
        data = resp.json()
        _logger.debug(f'/api/v1/octo/verify/ response payload: {data}. Updating the auth_token in the config file')
        auth_token = data['printer']['auth_token']
        config.update_server_auth_token(auth_token)

    return resp
