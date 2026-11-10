package com.pilipala.marcomovie;

import org.json.*;
import java.io.*;
import java.util.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;

/** Source-only comment decoding, independent of the screen and network. */
final class DanmakuData {
    static final class Comment {
        long time;
        int mode = 1, color = 0xffffff;
        String text;
        float cachedWidth;
        float cachedTextSize;
    }

    private static String stripIllegalXmlChars(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == 0x9
                    || ch == 0xA
                    || ch == 0xD
                    || (ch >= 0x20 && ch <= 0xD7FF)
                    || (ch >= 0xE000 && ch <= 0xFFFD)) {
                sb.append(ch);
            }
        }
        return sb.toString();
    }

    private static String unescapeXmlText(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String s = raw.trim();
        if (s.startsWith("<![CDATA[") && s.endsWith("]]>")) {
            s = s.substring(9, s.length() - 3);
        } else {
            s = s.replaceAll("<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>", "$1");
        }
        return s.replace("&amp;", "&")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&apos;", "'")
                .replace("&#39;", "'");
    }

    static List<Comment> parse(String text) throws Exception {
        if (text.length() > 8 * 1024 * 1024) throw new IOException("弹幕文件过大");
        List<Comment> out = new ArrayList<>();
        String content = text.trim().replaceFirst("^\\uFEFF", "");
        if (content.startsWith("<")) {
            if (content.toUpperCase(Locale.ROOT).contains("<!DOCTYPE")
                    || content.toUpperCase(Locale.ROOT).contains("<!ENTITY"))
                throw new IOException("弹幕不能包含外部实体");
            String sanitized = stripIllegalXmlChars(content);
            try {
                DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
                f.setExpandEntityReferences(false);
                Document d =
                        f.newDocumentBuilder()
                                .parse(new ByteArrayInputStream(sanitized.getBytes("UTF-8")));
                NodeList nodes = d.getElementsByTagName("d");
                for (int i = 0; i < Math.min(20000, nodes.getLength()); i++) {
                    Element element = (Element) nodes.item(i);
                    String[] p = element.getAttribute("p").split(",");
                    if (p.length < 4) continue;
                    try {
                        Comment c = new Comment();
                        c.time = (long) (Double.parseDouble(p[0].trim()) * 1000);
                        c.mode = Integer.parseInt(p[1].trim());
                        c.color = Integer.parseInt(p[3].trim());
                        c.text = element.getTextContent();
                        add(out, c);
                    } catch (NumberFormatException ignored) {
                    }
                }
            } catch (Exception domError) {
                java.util.regex.Matcher m =
                        java.util.regex.Pattern.compile(
                                        "<d\\b[^>]*\\bp\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</d>",
                                        java.util.regex.Pattern.CASE_INSENSITIVE)
                                .matcher(sanitized);
                int count = 0;
                while (m.find() && count < 20000) {
                    count++;
                    String[] p = m.group(1).split(",");
                    if (p.length < 4) continue;
                    try {
                        Comment c = new Comment();
                        c.time = (long) (Double.parseDouble(p[0].trim()) * 1000);
                        c.mode = Integer.parseInt(p[1].trim());
                        c.color = Integer.parseInt(p[3].trim());
                        c.text = unescapeXmlText(m.group(2));
                        add(out, c);
                    } catch (NumberFormatException ignored) {
                    }
                }
                if (count == 0
                        && !sanitized.contains("<i")
                        && !sanitized.contains("<packet")
                        && !sanitized.contains("<danmaku")) {
                    throw domError;
                }
            }
        } else {
            Object root = new JSONTokener(content).nextValue();
            JSONArray list = null;
            if (root instanceof JSONArray) {
                list = (JSONArray) root;
            } else if (root instanceof JSONObject) {
                JSONObject obj = (JSONObject) root;
                for (String key :
                        new String[] {"danmuku", "danmaku", "danmu", "comments", "data", "list"}) {
                    list = obj.optJSONArray(key);
                    if (list != null) break;
                }
                if (list == null) {
                    JSONObject inner = obj.optJSONObject("data");
                    if (inner != null) {
                        for (String key :
                                new String[] {"danmuku", "danmaku", "danmu", "comments", "list"}) {
                            list = inner.optJSONArray(key);
                            if (list != null) break;
                        }
                    }
                }
            }
            if (list == null) throw new IOException("弹幕列表为空");
            for (int i = 0; i < Math.min(20000, list.length()); i++)
                try {
                    Comment c = new Comment();
                    Object item = list.get(i);
                    if (item instanceof JSONArray) {
                        JSONArray a = (JSONArray) item;
                        c.time = (long) (a.getDouble(0) * 1000);
                        c.mode = a.optInt(1, 1);
                        c.color = a.optInt(2, 0xffffff);
                        c.text = a.optString(3);
                    } else if (item instanceof JSONObject) {
                        JSONObject o = (JSONObject) item;
                        c.time = (long) (o.optDouble("time", o.optDouble("t", 0)) * 1000);
                        c.mode = o.optInt("mode", 1);
                        c.color = o.optInt("color", 0xffffff);
                        c.text = o.optString("text", o.optString("m", o.optString("content")));
                        if (o.has("p")) {
                            String[] p = o.getString("p").split(",");
                            c.time = (long) (Double.parseDouble(p[0]) * 1000);
                            if (p.length > 2) {
                                int v1 = Integer.parseInt(p[1].trim());
                                int v2 = Integer.parseInt(p[2].trim());
                                if (v1 <= 8 && v2 > 8) {
                                    c.mode = v1;
                                    c.color = v2;
                                } else {
                                    c.color = v1;
                                    c.mode = v2;
                                }
                            } else if (p.length > 1) {
                                c.color = Integer.parseInt(p[1].trim());
                            }
                        }
                    } else continue;
                    add(out, c);
                } catch (Exception ignored) {
                }
        }
        Collections.sort(out, (a, b) -> a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
        return out;
    }

    static void add(List<Comment> out, Comment c) {
        if (c.time < 0 || c.text == null || c.text.trim().isEmpty()) return;
        c.text = c.text.replaceAll("[\\p{Cntrl}]", " ");
        if (c.text.length() > 180) c.text = c.text.substring(0, 180);
        out.add(c);
    }
}
