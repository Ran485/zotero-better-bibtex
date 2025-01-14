import type { MarkupNode } from '../typings/markup'

import parse5 = require('parse5/lib/parser')
const htmlParser = new parse5({ sourceCodeLocationInfo: true })
import { titleCase } from './case'

import charCategories = require('xregexp/tools/output/categories')

const re = {
  Nl: charCategories.find(cat => cat.alias === 'Letter_Number').bmp,
  Nd: charCategories.find(cat => cat.alias === 'Decimal_Number').bmp,
  Mn: charCategories.find(cat => cat.alias === 'Nonspacing_Mark').bmp,
  Mc: charCategories.find(cat => cat.alias === 'Spacing_Mark').bmp,
  Lu: charCategories.find(cat => cat.alias === 'Uppercase_Letter').bmp,
  Lt: charCategories.find(cat => cat.alias === 'Titlecase_Letter').bmp,
  Ll: charCategories.find(cat => cat.alias === 'Lowercase_Letter').bmp,
  Lm: charCategories.find(cat => cat.alias === 'Modifier_Letter').bmp,
  Lo: charCategories.find(cat => cat.alias === 'Other_Letter').bmp,

  // punctuation
  P: /\.\u002D\u2000-\u206F\u2E00-\u2E7F\\'!"#\$%&\(\)\*\+,\/:;<=>\?@\[\]^_`{\|}~/.source,
  // P: charCategories.find(cat => cat.alias === 'Punctuation').bmp,

  Whitespace: / \t\n\r\u00A0/.source,

  // calculated below
  lcChar: null,
  char: null,
  protectedWord: null,

  leadingUnprotectedWord: null,
  protectedWords: null,
  unprotectedWord: null,
  url: null,
  whitespace: null,
}

// eslint-disable-next-line @typescript-eslint/restrict-plus-operands
re.lcChar = re.Ll + re.Lt + re.Lm + re.Lo + re.Mn + re.Mc + re.Nd + re.Nl
// eslint-disable-next-line @typescript-eslint/restrict-plus-operands
re.char = re.Lu + re.lcChar
re.protectedWord = `[${re.lcChar}]*[${re.Lu}][${re.char}]*`

/* actual regexps */

/* TODO: add punctuation */
re.leadingUnprotectedWord = new RegExp(`^([${re.Lu}][${re.lcChar}]*)[${re.Whitespace}${re.P}]`)
re.protectedWords = new RegExp(`^(${re.protectedWord})(([${re.Whitespace}])(${re.protectedWord}))*`)
re.unprotectedWord = new RegExp(`^[${re.char}]+`)
re.url = /^(https?|mailto):\/\/[^\s]+/
re.whitespace = new RegExp(`^[${re.Whitespace}]+`)

/* eslint-disable quote-props */
const ligatures = {
  '\u01F1': 'DZ',
  '\u01F2': 'Dz',
  '\u01F3': 'dz',
  '\u01C4': 'D\u017D',
  '\u01C5': 'D\u017E',
  '\u01C6': 'd\u017E',
  '\uFB00': 'ff',
  '\uFB01': 'fi',
  '\uFB02': 'fl',
  '\uFB03': 'ffi',
  '\uFB04': 'ffl',
  '\uFB05': '\u017Ft',
  '\uFB06': 'st',
  '\u0132': 'IJ',
  '\u0133': 'ij',
  '\u01C7': 'LJ',
  '\u01C8': 'Lj',
  '\u01C9': 'lj',
  '\u01CA': 'NJ',
  '\u01CB': 'Nj',
  '\u01CC': 'nj',
}
/* eslint-enable */

// export singleton: https://k94n.com/es6-modules-single-instance-pattern

type HTMLParserOptions = {
  html?: boolean
  caseConversion?: boolean
  exportBraceProtection: boolean
  csquotes: string
  exportTitleCase: boolean
}

export const HTMLParser = new class { // eslint-disable-line @typescript-eslint/naming-convention,no-underscore-dangle,id-blacklist,id-match
  private caseConversion: boolean
  private braceProtection: boolean
  private sentenceStart: boolean
  private spuriousNode = new Set(['#document-fragment', '#document', 'div', 'span'])
  private titleCased: string
  private html: string
  private ligatures = new RegExp(`[${Object.keys(ligatures).join('')}]`, 'g')

  public parse(html, options: HTMLParserOptions): MarkupNode {
    this.html = html

    let doc: MarkupNode

    this.caseConversion = options.caseConversion
    this.braceProtection = options.caseConversion && options.exportBraceProtection
    this.sentenceStart = true

    // add enquote tags.
    const csquotes = options.csquotes
    if (csquotes) {
      const space = '\\s*'
      for (const close of [0, 1]) {
        const chars = csquotes.replace(/./g, (c: string, i: number) => [c, ''][(i + close) & 1]).replace(/[-[\]/{}()*+?.\\^$|]\s*/g, '\\$&') // eslint-disable-line no-bitwise
        this.html = this.html.replace(new RegExp(`${close ? space : ''}[${chars}]${close ? '' : space}`, 'g'), close ? '</span>' : '<span class="enquote">')
      }
    }

    if (!options.html) {
      this.html = this.html.replace(/&/g, '&amp;')

      // this pseudo-html is a PITA to parse
      this.html = this.html.replace(/<(\/?)([^<>]*)>/g, (match, close, body) => {
        if (body.match(/^(emphasis|span|nc|sc|i|b|sup|sub|script)($|\n|\s)/i)) return match

        // I should have used script from the start
        // I think pre follows different rules where it still interprets what's inside; script just gives whatever is in there as-is
        if (body.match(/^pre$/i)) return `<${close || ''}script>`

        return match.replace(/</g, '&lt;').replace(/>/g, '&gt;')
      })
    }

    doc = this.walk(htmlParser.parseFragment(this.html))

    if (options.caseConversion) {
      if (options.exportTitleCase) {
        this.titleCased = ''
        this.collectText(doc)
        this.titleCased = titleCase(this.titleCased)

        this.titleCase(doc)
      }

      const unwrapped = this.unwrapNocase(doc)
      if (unwrapped.length === 1) {
        doc = unwrapped[0]
      }
      else {
        doc = { nodeName: 'span', attr: {}, class: {}, childNodes: unwrapped }
      }
      this.cleanupNocase(doc)
    }

    // spurious wrapping span
    doc = this.unwrapSpurious(doc)
    doc.source = this.html

    return doc
  }

  private titleCase(node: MarkupNode) {
    if (node.nodeName === '#text') {
      node.value = this.titleCased.substr(node.titleCased, node.value.length)
      return
    }

    for (const child of node.childNodes) {
      if (child.nocase || child.nodeName === 'sup' || child.nodeName === 'sub') continue
      this.titleCase(child)
    }
  }

  private unwrapSpurious(node: MarkupNode) {
    // debug('spurious:', { nodeName: node.nodeName, attrs: Object.keys(node.attr).length, nocase: node.nocase, childNodes: node.childNodes.length })

    if (node.nodeName === '#text') return node

    node.childNodes = node.childNodes.map(child => this.unwrapSpurious(child))

    while (this.spuriousNode.has(node.nodeName) && Object.keys(node.attr).length === 0 && !node.nocase && node.childNodes.length === 1) node = node.childNodes[0]

    return node
  }

  // BibLaTeX is beyond insane https://github.com/retorquere/zotero-better-bibtex/issues/541#issuecomment-240999396
  private unwrapNocase(node: MarkupNode): MarkupNode[] {
    if (node.nodeName === '#text') return [ node ]

    // unwrap and flatten
    node.childNodes = [].concat(...node.childNodes.map(child => this.unwrapNocase(child)))

    // no nocase children? done
    if (node.nocase || !node.childNodes.find(child => child.nocase)) return [ node ]

    // expand nested nocase node to sibling of node
    return node.childNodes.map((child: MarkupNode) => {
      if (child.nocase) {
        return {
          ...child,
          childNodes: [ { ...node, childNodes: child.childNodes } ],
        }
      }

      return {
        ...node,
        childNodes: [ child ],
      }
    })
  }

  private cleanupNocase(node: MarkupNode, nocased = false): MarkupNode[] {
    if (node.nodeName === '#text') return null

    if (nocased) delete node.nocase

    for (const child of node.childNodes) {
      this.cleanupNocase(child, node.nocase || nocased)
    }
  }

  private collectText(node: MarkupNode) {
    switch (node.nodeName) {
      case '#text':
        node.titleCased = this.titleCased.length
        this.titleCased += node.value
        break

      case 'script':
        // don't confuse the title caser with spurious markup. Without this,
        // the CSL title caser would consider last words in a title that actually have a following <script> block the last
        // word and would capitalize it. The prevents that behavior by adding the contents of the <script> block, but it
        // will be ignored by the BBT title caser, which only title-cases #text blocks
        this.titleCased += ''.padStart(node.value.length, 'latex')
        break

      default:
        for (const child of node.childNodes) {
          this.collectText(child)
        }
    }
  }

  private plaintext(childNodes: MarkupNode[], text, offset) {
    // replace ligatures so titlecasing works for things like "figures"
    text = text.replace(this.ligatures, (ligature: string) => (ligatures[ligature] as string))
    const l = childNodes.length
    if (l === 0 || (childNodes[l - 1].nodeName !== '#text')) {
      childNodes.push({ nodeName: '#text', offset, value: text, attr: {}, class: {} })
    }
    else {
      childNodes[l - 1].value += text
    }
  }

  private nocase(childNodes, text, offset) {
    childNodes.push({
      nodeName: 'span',
      nocase: true,
      attr: {},
      class: {},
      childNodes: [{
        nodeName: '#text',
        offset,
        value: text,
        attr: {},
        class: {},
      }],
    })
  }

  private walk(node, isNocased = false) {
    // debug('walk:', node.nodeName)
    const normalized_node: MarkupNode = { nodeName: node.nodeName, childNodes: [], attr: {}, class: {} }
    for (const {name, value} of (node.attrs || [])) {
      normalized_node.attr[name] = value
    }
    for (const cls of (normalized_node.attr.class || '').trim().split(/\s+/)) {
      if (cls) normalized_node.class[cls] = true
    }
    switch (node.type?.toLowerCase()) {
      case 'smallcaps':
        normalized_node.attr.smallcaps = 'smallcaps'
        break
    }
    if (node.type) normalized_node.class[node.type] = true

    switch (node.nodeName) {
      case '#document':
      case '#document-fragment':
      case 'pre':
        normalized_node.nodeName = 'span'
        break

      case 'nc':
        normalized_node.nodeName = 'span'
        normalized_node.attr.nocase = 'nocase'
        break

      case 'emphasis':
        normalized_node.nodeName = 'i'
        break

      case 'sc':
        normalized_node.nodeName = 'span'
        normalized_node.attr.smallcaps = 'smallcaps'
        break
    }

    if (normalized_node.attr.nocase || normalized_node.class.nocase) normalized_node.nocase = !isNocased
    if (normalized_node.attr.relax || normalized_node.class.relax) normalized_node.relax = true
    if (normalized_node.class.enquote || normalized_node.attr.enquote) normalized_node.enquote = true
    if (!normalized_node.attr.smallcaps && (normalized_node.attr.style || '').match(/small-caps/i)) normalized_node.attr.smallcaps = 'smallcaps'
    if (normalized_node.class.smallcaps || normalized_node.attr.smallcaps) normalized_node.smallcaps = true

    if (normalized_node.nodeName === 'script') {
      if (!node.childNodes || node.childNodes.length === 0) {
        normalized_node.value =  ''
        normalized_node.childNodes = []
      }
      else if (node.childNodes.length === 1 && node.childNodes[0].nodeName === '#text') {
        normalized_node.value =  node.childNodes[0].value
        normalized_node.childNodes = []
      }
      else {
        throw new Error(`Unexpected script body ${JSON.stringify(node)}`)
      }

    }
    else if (node.childNodes) {
      let m
      for (const child of node.childNodes) {
        if (child.nodeName !== '#text') {
          normalized_node.childNodes.push(this.walk(child, isNocased || normalized_node.nocase))
          continue
        }

        if (!this.caseConversion || isNocased) {
          this.plaintext(normalized_node.childNodes, child.value, child.sourceCodeLocation.startOffset)
          continue
        }

        let text = child.value
        const length = text.length
        while (text) {
          if (m = re.whitespace.exec(text)) {
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.plaintext(normalized_node.childNodes, m[0], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(m[0].length)
            continue
          }

          if (this.sentenceStart && (m = re.leadingUnprotectedWord.exec(`${text} `))) {
            this.sentenceStart = false
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.plaintext(normalized_node.childNodes, m[1], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(m[1].length)
            continue
          }

          this.sentenceStart = false

          if (!isNocased && this.braceProtection && (m = re.protectedWords.exec(text))) {
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.nocase(normalized_node.childNodes, m[0], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(m[0].length)

          }
          else if (m = re.url.exec(text)) {
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.nocase(normalized_node.childNodes, m[0], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(m[0].length)

          }
          else if (m = re.unprotectedWord.exec(text)) {
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.plaintext(normalized_node.childNodes, m[0], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(m[0].length)

          }
          else {
            // eslint-disable-next-line @typescript-eslint/restrict-plus-operands
            this.plaintext(normalized_node.childNodes, text[0], child.sourceCodeLocation.startOffset + (length - text.length))
            text = text.substring(1)
          }
        }
      }
    }

    return normalized_node
  }
}
