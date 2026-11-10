"""Self-authored HTML contract, also executable by CPython + BeautifulSoup."""
import json
import re
from bs4 import BeautifulSoup


def contract():
    html = '''<!doctype html><section><div class="swiper-slide featured"><a href="/first?q=one&amp;two">  One &amp; <em> Two </em> 三  </a><img data-src="p&amp;q.jpg"></div><div class="swiper-slide swiper-slide-duplicate"><a href="/duplicate">duplicate</a></div><div class="last">last</div><!-- hidden --><script>hidden script</script><style>hidden style</style></section>'''
    soup = BeautifulSoup(html, 'html.parser')
    anchor = soup.select_one('.swiper-slide:not(.swiper-slide-duplicate) a')
    attributes = BeautifulSoup('<a REL="tag next" class="a b" href="" disabled data-id="x">&nbsp;&#x4e2d;&lt;</a><input checked><p>first<br>second', 'html.parser')
    link = attributes.select_one('a')
    special = BeautifulSoup('<script>x</script><style>y</style><template>z<b>u</b></template><ruby>a<rt>b</rt><rp>c</rp></ruby>', 'html.parser')
    return {
        'href': anchor.get('href'),
        'text': anchor.text,
        'joined': anchor.get_text(' ', strip=True),
        'union': [n.get('class') for n in soup.select('.last, .featured')],
        'missing': soup.select_one('#missing') is None,
        'fallback': anchor.get('missing', 'fallback'),
        'none': anchor.get('missing'),
        'picture': soup.select_one('.featured img').get('data-src'),
        'document_text': soup.get_text('|', strip=True),
        'nested': soup.select_one('section').select_one('.featured').get('class'),
        'child': len(soup.select('section > div:not(.swiper-slide-duplicate)')),
        'nth': soup.select_one('div:nth-child(3)').text,
        'attributes': [link.get('rel'), link.get('class'), link.get('href'), link.get('disabled'), attributes.select_one('input').get('checked')],
        'attribute_selector': attributes.select_one('[data-id="x"]').get_text(' ', strip=True),
        'unclosed': attributes.select_one('p').get_text('|'),
        'unicode_whitespace': BeautifulSoup('<p>\u2003中文&nbsp;<b> 二 </b></p>', 'html.parser').get_text('/', strip=True),
        'empty': BeautifulSoup('', 'html.parser').select_one('div') is None,
        'root_not_selected': soup.select_one('section').select_one('section') is None,
        'special_document': special.get_text('|'),
        'special_tag_text': [special.select_one(name).get_text('|') for name in ['script', 'style', 'template', 'b', 'ruby', 'rt', 'rp']],
        'regex': {
            'actor': re.sub(r'演员：\s*', '', '演员： 甲 乙'),
            'line': re.sub(r'[#\s]+', ' ', '## A\t 线').strip(),
            'unicode_space': re.sub(r'\s+', '/', '\u0085\u001c\u2003a\ufeffb'),
            'unicode_word': re.sub(r'\w+', 'X', '中文²_ a!'),
            'unicode_decimal': re.sub(r'\d+', 'N', '１２ ² 123'),
            'backrefs': re.sub(r'([{,]\s*)(\w+)\s*:', r'\1"\2":', '{name:1, 中文:2}'),
            'group_zero': re.sub(r'(a)(b)?', r'\g<0>-\2-\1', 'a ab'),
            'literal_dollar': re.sub('a', '$&', 'aa'),
            'count': re.sub('a', 'x', 'aaa', count=2),
            'negative_count': re.sub('a', 'x', 'aaa', count=-1),
            'ignorecase': re.sub('a', 'x', 'Aa', flags=re.I),
            'multiline': re.sub('^a', 'x', 'a\na', flags=re.M),
            'subn': re.subn('a', 'x', 'aba'),
            'escapes': re.sub('a', r'\n\t\\\101', 'a'),
        },
    }


class Spider:
    def homeContent(self, filter): return contract()


if __name__ == '__main__':
    print(json.dumps(contract(), ensure_ascii=False, indent=2))
