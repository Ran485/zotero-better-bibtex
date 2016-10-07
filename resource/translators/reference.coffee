###
# h1 Global object: Translator
#
# The global Translator object allows access to the current configuration of the translator
#
# @param {enum} caseConversion whether titles should be title-cased and case-preserved
# @param {boolean} bibtexURL set to true when BBT will generate \url{..} around the urls for BibTeX
###

###
# h1 class: Reference
#
# The Bib(La)TeX references are generated by the `Reference` class. Before being comitted to the cache, you can add
# postscript code that can manipulated the `fields` or the `referencetype`
#
# @param {Array} @fields Array of reference fields
# @param {String} @referencetype referencetype
# @param {Object} @item the current Zotero item being converted
###

###
# The fields are objects with the following keys:
#   * name: name of the Bib(La)TeX field
#   * value: the value of the field
#   * bibtex: the LaTeX-encoded value of the field
#   * enc: the encoding to use for the field
###
class Reference
  constructor: (@item) ->
    @fields = []
    @has = Object.create(null)
    @raw = (Translator.rawLaTag in @item.tags)
    @data = {DeclarePrefChars: ''}

    if !@item.language
      @english = true
      Translator.debug('detecting language: defaulting to english')
    else
      langlc = @item.language.toLowerCase()
      @language = Language.babelMap[langlc.replace(/[^a-z0-9]/, '_')]
      @language ||= Language.babelMap[langlc.replace(/-[a-z]+$/i, '').replace(/[^a-z0-9]/, '_')]
      @language ||= Language.fromPrefix(langlc)
      Translator.debug('detecting language:', {langlc, language: @language})
      if @language
        @language = @language[0]
      else
        sim = Language.lookup(langlc)
        if sim[0].sim >= 0.9
          @language = sim[0].lang
        else
          @language = @item.language

      @english = @language in ['american', 'british', 'canadian', 'english', 'australian', 'newzealand', 'USenglish', 'UKenglish']
      Translator.debug('detected language:', {language: @language, english: @english})

    @referencetype = Translator.typeMap.Zotero2BibTeX[@item.itemType] || 'misc'

    @override = Translator.extractFields(@item)
    Translator.debug('postextract: item:', @item)
    Translator.debug('postextract: overrides:', @override)

    for own attr, f of Translator.fieldMap || {}
      @add(@clone(f, @item[attr])) if f.name

    @add({name: 'timestamp', value: Translator.testing_timestamp || @item.dateModified || @item.dateAdded})

    switch
      when (@item.libraryCatalog || '').toLowerCase() in ['arxiv.org', 'arxiv'] && (@item.arXiv = @arXiv.parse(@item.publicationTitle))
        @item.arXiv.source = 'publicationTitle'
        delete @item.publicationTitle if Translator.BetterBibLaTeX

      when @override.arxiv && (@item.arXiv = @arXiv.parse('arxiv:' + @override.arxiv.value))
        @item.arXiv.source = 'extra'

    if @item.arXiv
      @add({ archivePrefix: 'arXiv'} )
      @add({ eprinttype: 'arxiv'})
      @add({ eprint: @item.arXiv.eprint })
      @add({ primaryClass: @item.arXiv.primaryClass }) if @item.arXiv.primaryClass
      delete @override.arxiv

  arXiv:
    # new-style IDs
    # arXiv:0707.3168 [hep-th]
    # arXiv:YYMM.NNNNv# [category]
    new: /^arxiv:([0-9]{4}\.[0-9]+)(v[0-9]+)?(\s+\[(.*)\])?$/i

    # arXiv:arch-ive/YYMMNNNv# or arXiv:arch-ive/YYMMNNNv# [category]
    old: /^arxiv:([a-z]+-[a-z]+\/[0-9]{7})(v[0-9]+)?(\s+\[(.*)\])?$/i

    # bare
    bare: /^arxiv:\s*([\S]+)/i

    parse: (id) ->
      return undefined unless id

      if m = @new.exec(id)
        return { id, eprint: m[1], primaryClass: m[4] }
      if m = @old.exec(id)
        return { id, eprint: m[1], primaryClass: m[4] }
      if m = @bare.exec(id)
        return { id, eprint: m[1] }

      return undefined

  ###
  # Return a copy of the given `field` with a new value
  #
  # @param {field} field to be cloned
  # @param {value} value to be assigned
  # @return {Object} copy of field settings with new value
  ###
  clone: (f, value) ->
    clone = JSON.parse(JSON.stringify(f))
    delete clone.bibtex
    clone.value = value
    return clone

  ###
  # 'Encode' to raw LaTeX value
  #
  # @param {field} field to encode
  # @return {String} unmodified `field.value`
  ###
  enc_raw: (f) ->
    return f.value

  ###
  # Encode to date
  #
  # @param {field} field to encode
  # @return {String} unmodified `field.value`
  ###
  isodate: (v, suffix = '') ->
    year = v["year#{suffix}"]
    return null unless year

    month = v["month#{suffix}"]
    month = "0#{month}".slice(-2) if month
    day = v["day#{suffix}"]
    day = "0#{day}".slice(-2) if day

    date = '' + year
    if month
      date += "-#{month}"
      date += "-#{day}" if day
    return date

  enc_date: (f) ->
    return null unless f.value

    value = f.value
    value = Zotero.BetterBibTeX.parseDateToObject(value, @item.language) if typeof f.value == 'string'

    if value.literal
      return '\\bibstring{nodate}' if value.literal == 'n.d.'
      return @enc_latex(@clone(f, value.literal))

    date = @isodate(value)
    return null unless date

    enddate = @isodate(value, '_end')
    date += "/#{enddate}" if enddate

    return @enc_latex({value: date})

  ###
  # Encode to LaTeX url
  #
  # @param {field} field to encode
  # @return {String} field.value encoded as verbatim LaTeX string (minimal escaping). If in Better BibTeX, wraps return value in `\url{string}`
  ###
  enc_url: (f) ->
    value = @enc_verbatim(f)
    if Translator.BetterBibTeX
      return "\\url{#{@enc_verbatim(f)}}"
    else
      return value

  ###
  # Encode to verbatim LaTeX
  #
  # @param {field} field to encode
  # @return {String} field.value encoded as verbatim LaTeX string (minimal escaping).
  ###
  enc_verbatim: (f) ->
    return @toVerbatim(f.value)

  nonLetters: new XRegExp("[^\\p{Letter}]", 'g')
  punctuationAtEnd: new XRegExp("[\\p{Punctuation}]$")
  startsWithLowercase: new XRegExp("^[\\p{Ll}]")
  hasLowercaseWord: new XRegExp("\\s[\\p{Ll}]")
  _enc_creators_pad_particle: (particle, relax) ->
    # space at end is always OK
    return particle if particle[particle.length - 1] == ' '

    if Translator.BetterBibLaTeX
      @data.DeclarePrefChars += particle[particle.length - 1] if XRegExp.test(particle, @punctuationAtEnd)
      # if BBLT, always add a space if it isn't there
      return particle + ' '

    # otherwise, we're in BBT.

    # If the particle ends in a period, add a space
    return particle + ' ' if particle[particle.length - 1] == '.'

    # if it ends in any other punctuation, it's probably something like d'Medici -- no space
    return particle + @_enc_creators_relax_marker + ' ' if relax && XRegExp.test(particle, @punctuationAtEnd)

    # otherwise, add a space
    return particle + ' '

  _enc_creators_quote_separators: (value) ->
    return ((if i % 2 == 0 then n else new String(n)) for n, i in value.split(/(\s+and\s+|,)/i))

  _enc_creators_biblatex: (name) ->
    if name.family.length > 1 && name.family[0] == '"' && name.family[name.family.length - 1] == '"'
      family = new String(name.family.slice(1, -1))
    else
      family = name.family

    family = new String(family) if family && XRegExp.test(family, @startsWithLowercase)

    family = @enc_latex({value: family}) if family

    latex = ''
    latex += @enc_latex({value: @_enc_creators_pad_particle(name['dropping-particle'])}) if name['dropping-particle']
    latex += @enc_latex({value: @_enc_creators_pad_particle(name['non-dropping-particle'])}) if name['non-dropping-particle']
    latex += family if family
    latex += ', ' + @enc_latex({value: name.suffix}) if name.suffix
    latex += ', ' + @enc_latex({value: name.given}) if name.given

    return latex

  _enc_creators_bibtex: (name) ->
    if name.family.length > 1 && name.family[0] == '"' && name.family[name.family.length - 1] == '"'
      family = new String(name.family.slice(1, -1))
    else
      family = name.family

    ###
      TODO: http://chat.stackexchange.com/rooms/34705/discussion-between-retorquere-and-egreg

      My advice is never using the alpha style; it's a relic of the past, when numbering citations was very difficult
      because one didn't know the full citation list when writing a paper. In order to have the bibliography in
      alphabetical order, such tricks were devised. The alternative was listing the citation in order of appearance.
      Your document gains nothing with something like XYZ88 as citation key.

      The “van” problem should be left to the bibliographic style. Some styles consider “van” as part of the name, some
      don't. In any case, you'll have a kludge, mostly unportable. However, if you want van Gogh to be realized as vGo
      in the label, use {\relax van} Gogh or something like this.
    ###

    family = @_enc_creators_pad_particle(name['non-dropping-particle']) + family if name['non-dropping-particle']
    family = new String(family) if XRegExp.test(family, @startsWithLowercase) || XRegExp.test(family, @hasLowercaseWord)
    family = @enc_latex({value: family})
    family = @enc_latex({value: @_enc_creators_pad_particle(name['dropping-particle'], true)}) + family if name['dropping-particle']

    if Translator.BetterBibTeX && Translator.bibtexNoopSortForParticles && (name['non-dropping-particle'] || name['dropping-particle'])
      family = '\\noopsort{' + @enc_latex({value: name.family.toLowerCase()}) + '}' + family
      Translator.preamble.noopsort = true

    name.given = @enc_latex({value: name.given}) if name.given
    name.suffix = @enc_latex({value: name.suffix}) if name.suffix

    latex = family
    latex += ", #{name.suffix}" if name.suffix
    latex += ", #{name.given}" if name.given

    return latex

  ###
  # Encode creators to author-style field
  #
  # @param {field} field to encode. The 'value' must be an array of Zotero-serialized `creator` objects.
  # @return {String} field.value encoded as author-style value
  ###
  _enc_creators_relax_block_marker: '\u0097'
  _enc_creators_relax_marker: '\u200C'
  enc_creators: (f, raw) ->
    return null if f.value.length == 0

    encoded = []
    for creator in f.value
      switch
        when creator.name || (creator.lastName && creator.fieldMode == 1)
          name = if raw then "{#{creator.name || creator.lastName}}" else @enc_latex({value: new String(creator.name || creator.lastName)})

        when raw
          name = [creator.lastName || '', creator.firstName || ''].join(', ')

        when creator.lastName || creator.firstName
          name = {family: creator.lastName || '', given: creator.firstName || ''}

          Zotero.BetterBibTeX.CSL.parseParticles(name)

          if name.given && name.given.indexOf(@_enc_creators_relax_block_marker) >= 0 # zero-width space
            name.given = '<span relax="true">' + name.given.replace(@_enc_creators_relax_block_marker, '</span>')

          @useprefix ||= !!name['non-dropping-particle']
          @juniorcomma ||= (f.juniorcomma && name['comma-suffix'])

          if Translator.BetterBibTeX
            name = @_enc_creators_bibtex(name)
          else
            name = @_enc_creators_biblatex(name)

        else
          continue

      encoded.push(name.trim())

    return encoded.join(' and ')

  ###
  # Encode text to LaTeX literal list (double-braced)
  #
  # This encoding supports simple HTML markup.
  #
  # @param {field} field to encode.
  # @return {String} field.value encoded as author-style value
  ###
  enc_literal: (f) ->
    return @enc_latex({value: new String(f.value)})

  ###
  # Encode text to LaTeX
  #
  # This encoding supports simple HTML markup.
  #
  # @param {field} field to encode.
  # @return {String} field.value encoded as author-style value
  ###
  enc_latex: (f, raw) ->
    Translator.debug('enc_latex:', {f, raw, english: @english})
    return f.value if typeof f.value == 'number'
    return null unless f.value

    if Array.isArray(f.value)
      return null if f.value.length == 0
      return (@enc_latex(@clone(f, word), raw) for word in f.value).join(f.sep || '')

    return f.value if f.raw || raw

    value = LaTeX.text2latex(f.value, {mode: (if f.html then 'html' else 'text'), caseConversion: f.caseConversion && @english})
    value = "{#{value}}" if f.caseConversion && Translator.BetterBibTeX && !@english

    value = new String("{#{value}}") if f.value instanceof String
    return value

  enc_tags: (f) ->
    tags = (tag for tag in f.value || [] when tag && tag != Translator.rawLaTag)
    return null if tags.length == 0

    # sort tags for stable tests
    tags.sort() if Translator.testing

    tags = for tag in tags
      if Translator.BetterBibTeX
        tag = tag.replace(/([#\\%&])/g, '\\$1')
      else
        tag = tag.replace(/([#%\\])/g, '\\$1')

      # the , -> ; is unfortunate, but I see no other way
      tag = tag.replace(/,/g, ';')

      # verbatim fields require balanced braces -- please just don't use braces in your tags
      balanced = 0
      for ch in tag
        switch ch
          when '{' then balanced += 1
          when '}' then balanced -= 1
        break if balanced < 0
      tag = tag.replace(/{/g, '(').replace(/}/g, ')') if balanced != 0
      tag

    return tags.join(',')

  enc_attachments: (f) ->
    return null if not f.value || f.value.length == 0
    attachments = []
    errors = []

    for attachment in f.value
      att = {
        title: attachment.title
        mimetype: attachment.contentType || ''
        path: attachment.defaultPath || attachment.localPath
      }

      continue unless att.path # amazon/googlebooks etc links show up as atachments without a path
      #att.path = att.path.replace(/^storage:/, '')
      att.path = att.path.replace(/(?:\s*[{}]+)+\s*/g, ' ')

      attachment.saveFile(att.path, true) if Translator.exportFileData && attachment.saveFile && attachment.defaultPath

      att.title ||= att.path.replace(/.*[\\\/]/, '') || 'attachment'

      att.mimetype = 'application/pdf' if !att.mimetype && att.path.slice(-4).toLowerCase() == '.pdf'

      switch
        when Translator.testing
          Translator.attachmentCounter += 1
          att.path = "files/#{Translator.attachmentCounter}/#{att.path.replace(/.*[\/\\]/, '')}"
        when Translator.exportPath && att.path.indexOf(Translator.exportPath) == 0
          att.path = att.path.slice(Translator.exportPath.length)

      attachments.push(att)

    f.errors = errors if errors.length != 0
    return null if attachments.length == 0

    # sort attachments for stable tests, and to make non-snapshots the default for JabRef to open (#355)
    attachments.sort((a, b) ->
      return 1  if a.mimetype == 'text/html' && b.mimetype != 'text/html'
      return -1 if b.mimetype == 'text/html' && a.mimetype != 'text/html'
      return a.path.localeCompare(b.path)
    )

    return (att.path.replace(/([\\{};])/g, "\\$1") for att in attachments).join(';') if Translator.attachmentsNoMetadata
    return ((part.replace(/([\\{}:;])/g, "\\$1") for part in [att.title, att.path, att.mimetype]).join(':') for att in attachments).join(';')

  isBibVarRE: /^[a-z][a-z0-9_]*$/i
  isBibVar: (value) ->
    return Translator.preserveBibTeXVariables && value && typeof value == 'string' && @isBibVarRE.test(value)
  ###
  # Add a field to the reference field set
  #
  # @param {field} field to add. 'name' must be set, and either 'value' or 'bibtex'. If you set 'bibtex', BBT will trust
  #   you and just use that as-is. If you set 'value', BBT will escape the value according the encoder passed in 'enc'; no
  #   'enc' means 'enc_latex'. If you pass both 'bibtex' and 'latex', 'bibtex' takes precedence (and 'value' will be
  #   ignored)
  ###
  add: (field) ->
    if !field.name
      for name, value of field
        field = {name, value}
        break
      return unless field.name && field.value

    if ! field.bibtex
      return if typeof field.value != 'number' && not field.value
      return if typeof field.value == 'string' && field.value.trim() == ''
      return if Array.isArray(field.value) && field.value.length == 0

    @remove(field.name) if field.replace
    throw "duplicate field '#{field.name}' for #{@item.__citekey__}" if @has[field.name] && !field.allowDuplicates

    if ! field.bibtex
      Translator.debug('add:', {
        field
        preserve: Translator.preserveBibTeXVariables
        match: @isBibVar(field.value)
      })
      if typeof field.value == 'number' || (field.preserveBibTeXVariables && @isBibVar(field.value))
        value = '' + field.value
      else
        enc = field.enc || Translator.fieldEncoding[field.name] || 'latex'
        value = @["enc_#{enc}"](field, @raw)

        return unless value

        value = "{#{value}}" unless field.bare && !field.value.match(/\s/)

      # separation protection at end unnecesary
      value = value.replace(/{}$/, '')

      field.bibtex = "#{value}"

    field.bibtex = field.bibtex.normalize('NFKC') if @normalize
    @fields.push(field)
    @has[field.name] = field
    Translator.debug('added:', field)

  ###
  # Remove a field from the reference field set
  #
  # @param {name} field to remove.
  # @return {Object} the removed field, if present
  ###
  remove: (name) ->
    return unless @has[name]
    removed = @has[name]
    delete @has[name]
    @fields = (field for field in @fields when field.name != name)
    return removed

  normalize: (typeof (''.normalize) == 'function')

  postscript: ->

  complete: ->
    if Translator.DOIandURL != 'both'
      if @has.doi && @has.url
        switch Translator.DOIandURL
          when 'doi' then @remove('url')
          when 'url' then @remove('doi')

    fields = []
    for own name, value of @override
      # psuedo-var, sets the reference type
      if name == 'referencetype'
        @referencetype = value.value
        continue

      # these are handled just like 'arxiv' and 'lccn', respectively
      if name in ['PMID', 'PMCID']
        value.format = 'key-value'
        name = name.toLowerCase()

      if value.format == 'csl'
        # CSL names are not in BibTeX format, so only add it if there's a mapping
        cslvar = Translator.CSLVariables[name]
        mapped = cslvar[(if Translator.BetterBibLaTeX then 'BibLaTeX' else 'BibTeX')]
        mapped = mapped.call(@) if typeof mapped == 'function'
        caseConversion = name in ['title', 'shorttitle', 'origtitle', 'booktitle', 'maintitle']

        if mapped
          fields.push({ name: mapped, value: value.value, caseConversion, raw: false, enc: (if cslvar.type == 'creator' then 'creators' else cslvar.type) })

        else
          Translator.debug('Unmapped CSL field', name, '=', value.value)

      else
        switch name
          when 'mr'
            fields.push({ name: 'mrnumber', value: value.value, raw: value.raw })
          when 'zbl'
            fields.push({ name: 'zmnumber', value: value.value, raw: value.raw })
          when 'lccn', 'pmcid'
            fields.push({ name: name, value: value.value, raw: value.raw })
          when 'pmid', 'arxiv', 'jstor', 'hdl'
            if Translator.BetterBibLaTeX
              fields.push({ name: 'eprinttype', value: name.toLowerCase() })
              fields.push({ name: 'eprint', value: value.value, raw: value.raw })
            else
              fields.push({ name, value: value.value, raw: value.raw })
          when 'googlebooksid'
            if Translator.BetterBibLaTeX
              fields.push({ name: 'eprinttype', value: 'googlebooks' })
              fields.push({ name: 'eprint', value: value.value, raw: value.raw })
            else
              fields.push({ name: 'googlebooks', value: value.value, raw: value.raw })
          when 'xref'
            fields.push({ name, value: value.value, raw: value.raw })

          else
            Translator.debug('fields.push', { name, value: value.value, raw: value.raw })
            fields.push({ name, value: value.value, raw: value.raw })

    for name in Translator.skipFields
      @remove(name)

    for field in fields
      name = field.name.split('.')
      if name.length > 1
        continue unless @referencetype == name[0]
        field.name = name[1]

      if (typeof field.value == 'string') && field.value.trim() == ''
        @remove(field.name)
        continue

      field = @clone(Translator.BibLaTeXDataFieldMap[field.name], field.value) if Translator.BibLaTeXDataFieldMap[field.name]
      field.replace = true
      @add(field)

    @add({name: 'type', value: @referencetype}) if @fields.length == 0

    try
      @postscript()
    catch err
      Translator.debug('postscript error:', err.message || err.name)

    # sort fields for stable tests
    @fields.sort((a, b) -> ("#{a.name} = #{a.value}").localeCompare(("#{b.name} = #{b.value}"))) if Translator.testing

    ref = "@#{@referencetype}{#{@item.__citekey__},\n"
    ref += ("  #{field.name} = #{field.bibtex}" for field in @fields).join(',\n')
    ref += '\n}\n'
    ref += "% Quality Report for #{@item.__citekey__}:\n#{qr}\n" if qr = @qualityReport()
    ref += "\n"
    Zotero.write(ref)

    @data.DeclarePrefChars = Translator.unique_chars(@data.DeclarePrefChars)

    Zotero.BetterBibTeX.cache.store(@item.itemID, Translator, @item.__citekey__, ref, @data) if Translator.caching

    Translator.preamble.DeclarePrefChars += @data.DeclarePrefChars if @data.DeclarePrefChars
    Translator.debug('item.complete:', {data: @data, preamble: Translator.preamble})

  toVerbatim: (text) ->
    if Translator.BetterBibTeX
      value = ('' + text).replace(/([#\\%&{}])/g, '\\$1')
    else
      value = ('' + text).replace(/([\\{}])/g, '\\$1')
    value = value.replace(/[^\x21-\x7E]/g, ((chr) -> '\\%' + ('00' + chr.charCodeAt(0).toString(16).slice(-2)))) if not Translator.unicode
    return value

  hasCreator: (type) -> (@item.creators || []).some((creator) -> creator.creatorType == type)

  qualityReport: ->
    return '' unless Translator.qualityReport
    fields = @requiredFields[@referencetype.toLowerCase()]
    return "% I don't know how to check #{@referencetype}" unless fields

    report = []
    for field in fields
      options = field.split('/')
      if (option for option in options when @has[option]).length == 0
        report.push("% Missing required field #{field}")

    if @referencetype == 'proceedings' && @has.pages
      report.push("% Proceedings with page numbers -- maybe his reference should be an 'inproceedings'")

    if @referencetype == 'article' && @has.journal
      report.push("% BibLaTeX uses journaltitle, not journal") if Translator.BetterBibLaTeX
      report.push("% Abbreviated journal title #{@has.journal.value}") if @has.journal.value.indexOf('.') >= 0

    if @referencetype == 'article' && @has.journaltitle
      report.push("% Abbreviated journal title #{@has.journaltitle.value}") if @has.journaltitle.value.indexOf('.') >= 0

    if @referencetype == 'inproceedings' and @has.booktitle
      if ! @has.booktitle.value.match(/:|Proceedings|Companion| '/) || @has.booktitle.value.match(/\.|workshop|conference|symposium/)
        report.push("% Unsure about the formatting of the booktitle")

    if @has.title
      if Translator.TitleCaser.titleCase(@has.title.value) == @has.title.value
        report.push("% Title looks like it was stored in title-case in Zotero")

    return report.join("\n")

Language = new class
  constructor: ->
    @babelMap = {
      af: 'afrikaans'
      am: 'amharic'
      ar: 'arabic'
      ast: 'asturian'
      bg: 'bulgarian'
      bn: 'bengali'
      bo: 'tibetan'
      br: 'breton'
      ca: 'catalan'
      cop: 'coptic'
      cy: 'welsh'
      cz: 'czech'
      da: 'danish'
      de_1996: 'ngerman'
      de_at_1996: 'naustrian'
      de_at: 'austrian'
      de_de_1996: 'ngerman'
      de: ['german', 'germanb']
      dsb: ['lsorbian', 'lowersorbian']
      dv: 'divehi'
      el: 'greek'
      el_polyton: 'polutonikogreek'
      en_au: 'australian'
      en_ca: 'canadian'
      en: 'english'
      en_gb: ['british', 'ukenglish']
      en_nz: 'newzealand'
      en_us: ['american', 'usenglish']
      eo: 'esperanto'
      es: 'spanish'
      et: 'estonian'
      eu: 'basque'
      fa: 'farsi'
      fi: 'finnish'
      fr_ca: [
        'acadian'
        'canadian'
        'canadien'
      ]
      fr: ['french', 'francais', 'français']
      fur: 'friulan'
      ga: 'irish'
      gd: ['scottish', 'gaelic']
      gl: 'galician'
      he: 'hebrew'
      hi: 'hindi'
      hr: 'croatian'
      hsb: ['usorbian', 'uppersorbian']
      hu: 'magyar'
      hy: 'armenian'
      ia: 'interlingua'
      id: [
        'indonesian'
        'bahasa'
        'bahasai'
        'indon'
        'meyalu'
      ]
      is: 'icelandic'
      it: 'italian'
      ja: 'japanese'
      kn: 'kannada'
      la: 'latin'
      lo: 'lao'
      lt: 'lithuanian'
      lv: 'latvian'
      ml: 'malayalam'
      mn: 'mongolian'
      mr: 'marathi'
      nb: ['norsk', 'bokmal', 'nob']
      nl: 'dutch'
      nn: 'nynorsk'
      no: ['norwegian', 'norsk']
      oc: 'occitan'
      pl: 'polish'
      pms: 'piedmontese'
      pt_br: ['brazil', 'brazilian']
      pt: ['portuguese', 'portuges']
      pt_pt: 'portuguese'
      rm: 'romansh'
      ro: 'romanian'
      ru: 'russian'
      sa: 'sanskrit'
      se: 'samin'
      sk: 'slovak'
      sl: ['slovenian', 'slovene']
      sq_al: 'albanian'
      sr_cyrl: 'serbianc'
      sr_latn: 'serbian'
      sr: 'serbian'
      sv: 'swedish'
      syr: 'syriac'
      ta: 'tamil'
      te: 'telugu'
      th: ['thai', 'thaicjk']
      tk: 'turkmen'
      tr: 'turkish'
      uk: 'ukrainian'
      ur: 'urdu'
      vi: 'vietnamese'
      zh_latn: 'pinyin'
      zh: 'pinyin'
      zlm: [
        'malay'
        'bahasam'
        'melayu'
      ]
    }
    for own key, value of @babelMap
      @babelMap[key] = [value] if typeof value == 'string'

    # list of unique languages
    @babelList = []
    for own k, v of @babelMap
      for lang in v
        @babelList.push(lang) if @babelList.indexOf(lang) < 0

    @cache = {}
    @prefix = {}

#  @polyglossia = [
#    'albanian'
#    'amharic'
#    'arabic'
#    'armenian'
#    'asturian'
#    'bahasai'
#    'bahasam'
#    'basque'
#    'bengali'
#    'brazilian'
#    'brazil'
#    'breton'
#    'bulgarian'
#    'catalan'
#    'coptic'
#    'croatian'
#    'czech'
#    'danish'
#    'divehi'
#    'dutch'
#    'english'
#    'british'
#    'ukenglish'
#    'esperanto'
#    'estonian'
#    'farsi'
#    'finnish'
#    'french'
#    'friulan'
#    'galician'
#    'german'
#    'austrian'
#    'naustrian'
#    'greek'
#    'hebrew'
#    'hindi'
#    'icelandic'
#    'interlingua'
#    'irish'
#    'italian'
#    'kannada'
#    'lao'
#    'latin'
#    'latvian'
#    'lithuanian'
#    'lsorbian'
#    'magyar'
#    'malayalam'
#    'marathi'
#    'nko'
#    'norsk'
#    'nynorsk'
#    'occitan'
#    'piedmontese'
#    'polish'
#    'portuges'
#    'romanian'
#    'romansh'
#    'russian'
#    'samin'
#    'sanskrit'
#    'scottish'
#    'serbian'
#    'slovak'
#    'slovenian'
#    'spanish'
#    'swedish'
#    'syriac'
#    'tamil'
#    'telugu'
#    'thai'
#    'tibetan'
#    'turkish'
#    'turkmen'
#    'ukrainian'
#    'urdu'
#    'usorbian'
#    'vietnamese'
#    'welsh'
#  ]

Language.get_bigrams = (string) ->
  s = string.toLowerCase()
  s = (s.slice(i, i + 2) for i in [0 ... s.length])
  s.sort()
  return s

Language.string_similarity = (str1, str2) ->
  pairs1 = @get_bigrams(str1)
  pairs2 = @get_bigrams(str2)
  union = pairs1.length + pairs2.length
  hit_count = 0

  while pairs1.length > 0 && pairs2.length > 0
    if pairs1[0] == pairs2[0]
      hit_count++
      pairs1.shift()
      pairs2.shift()
      continue

    if pairs1[0] < pairs2[0]
      pairs1.shift()
    else
      pairs2.shift()

  return (2 * hit_count) / union

Language.lookup = (langcode) ->
  if not @cache[langcode]
    @cache[langcode] = []
    for lc in Language.babelList
      @cache[langcode].push({ lang: lc, sim: @string_similarity(langcode, lc) })
    @cache[langcode].sort((a, b) -> b.sim - a.sim)

  return @cache[langcode]

Language.fromPrefix = (langcode) ->
  return false unless langcode && langcode.length >= 2

  unless @prefix[langcode]?
    # consider a langcode matched if it is the prefix of exactly one language in the map
    lc = langcode.toLowerCase()
    matches = []
    for code, languages of Language.babelMap
      for lang in languages
        continue if lang.toLowerCase().indexOf(lc) != 0
        matches.push(languages)
        break
    if matches.length == 1
      @prefix[langcode] = matches[0]
    else
      @prefix[langcode] = false

  return @prefix[langcode]
