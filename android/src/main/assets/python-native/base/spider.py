"""Candidate app-owned base contract. No empty catalog or proxy implementation."""
import requests


class Spider:
    def init(self, extend=""):
        self.extend = extend

    def fetch(self, url, **kwargs):
        return requests.get(url, **kwargs)

    def post(self, url, **kwargs):
        return requests.post(url, **kwargs)

    def getProxyUrl(self, params=None, local=True):
        return _HOST.proxy_url(params, local, legacy=True)

    def proxyUrl(self, params=None, local=True):
        return _HOST.proxy_url(params, local)

    def homeContent(self, filter):
        raise NotImplementedError("Python Spider is missing homeContent")

    def homeVideoContent(self):
        raise NotImplementedError("Python Spider is missing homeVideoContent")

    def categoryContent(self, tid, pg, filter, extend):
        raise NotImplementedError("Python Spider is missing categoryContent")

    def detailContent(self, ids):
        raise NotImplementedError("Python Spider is missing detailContent")

    def searchContent(self, key, quick, pg="1"):
        raise NotImplementedError("Python Spider is missing searchContent")

    def playerContent(self, flag, id, vipFlags):
        raise NotImplementedError("Python Spider is missing playerContent")

    # Do not declare localProxy/proxy: an inherited stub must not hide the other
    # real entrypoint supplied by a source.
