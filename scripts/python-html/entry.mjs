// Python uses htmlparser2 mode already; omit DRPY templating, crypto and parse5.
// This export path belongs to the pinned Cheerio 1.0.0-rc.12 package.
export {load} from 'cheerio/lib/slim';
