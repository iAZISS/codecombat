module.exports =
  dekuify: (elem) ->
    return elem.data if elem.type is 'text'
    return null if elem.type is 'comment'  # TODO: figure out how to make a comment in virtual dom
    elem.attribs = _.omit elem.attribs, (val, attr) -> attr.indexOf('<') > -1 # Deku chokes on `<thing <p></p>`
    unless elem.name
      console.log('Failed to dekuify', elem)
      return elem.type
    deku.element(elem.name, elem.attribs, (@dekuify(c) for c in elem.children ? []))

  undekuify: (dekuNode) ->
    return dekuNode if _.isString(dekuNode)
    results = _.filter _.flatten [dekuNode.nodeValue, (@undekuify(child) for child in (dekuNode.children or []))]

  # Parses user code into Deku format. Also guarantees an `html` and `body` element so that Deku doesn't explode when reading it.
  # Arguments:
  #   html — Raw HTML source code, possibly without html/body tags
  # Returns: Parsed Deku-format DOM that includes html/body tags
  parseUserHtml: (html) ->
    dom = htmlparser2.parseDOM html, {}
    bodyNode = _.find(dom, name: 'body') ? {name: 'body', attribs: null, children: dom}
    htmlNode = _.find(dom, name: 'html') ? {name: 'html', attribs: null, children: [bodyNode]}
    @dekuify(htmlNode)

  # Creates a deku virtual DOM for given HTML, with the <script> and <style> tags separated out (and dekuified as well)
  # Arguments:
  #   html — raw HTML source code
  # Returns: Object
  #   virtualDom: The DekuTree for the main content
  #   scripts: A list of Deku nodes for the <script> tags
  #   styles: A list of Deku nodes for the <style> tags
  extractStylesAndScripts: (html) ->
    dekuTree = @parseUserHtml(html)
    recurse = (dekuTree) ->
      #base case
      if dekuTree.type is '#text'
        return { virtualDom: dekuTree, styles: [], scripts: [] }
      if dekuTree.type is 'style'
        return { styles: [dekuTree], scripts: [] }
      if dekuTree.type is 'script'
        return { styles: [], scripts: [dekuTree] }
      # recurse over children
      childStyles = []
      childScripts = []
      dekuTree.children?.forEach (dekuChild, index) =>
        { virtualDom, styles, scripts } = recurse(dekuChild)
        dekuTree.children[index] = virtualDom
        childStyles = childStyles.concat(styles)
        childScripts = childScripts.concat(scripts)
      dekuTree.children = _.filter dekuTree.children # Remove the nodes we extracted
      return { virtualDom: dekuTree, scripts: childScripts, styles: childStyles }

    { virtualDom, scripts, styles } = recurse(dekuTree)
    wrappedStyles = deku.element('head', {}, styles)
    wrappedScripts = deku.element('head', {}, scripts)
    return { virtualDom, scripts: wrappedScripts, styles: wrappedStyles }

  # Returns a list of CSS selectors found in CSS code and jQuery calls
  extractCssSelectors: (dekuStyles, dekuScripts) ->
    # TODO: Move this hack for extracting CSS selectors
    cssSelectors = @extractSelectorsFromCss @undekuify(dekuStyles)

    # TODO: just do this in WebSurfaceView.onHoverLine?
    # Find all calls to $("...")
    jQuerySelectors = @extractSelectorsFromJS @undekuify(dekuScripts)
    return cssSelectors.concat(jQuerySelectors)

  # Returns a list of CSS selectors found in jQuery calls
  extractSelectorsFromCss: (styles) ->
    unless styles instanceof Array
      styles = [styles]
    cssSelectors = _.flatten styles.map (rawCss) ->
      try
        parsedCss = parseCss(rawCss) # TODO: Don't put this in the global namespace
        parsedCss.stylesheet.rules.map (rule) ->
          rule.selectors.join(', ').trim()
      catch e
        # TODO: Report this error, handle CSS errors in general
        []
    cssSelectors

  # Returns a list of CSS selector strings found in jQuery calls
  extractSelectorsFromJS: (scripts) ->
    jQuerySelectors = _.flatten scripts.map (script) ->
      script.match(/\$\(\s*['"](.*)['"]\s*\)/g) or [].map (jQueryCall) ->
        # Extract the argument (because capture groups don't work with /g)
        jQueryCall.match(/\$\(\s*['"](.*)['"]\s*\)/)[1]
    jQuerySelectors

  # Converts deku style nodes into a list of lines of CSS code.
  # Used to prefilter hovered lines for selectors.
  extractCssLines: (dekuStyles) ->
    rawCssLines = []
    dekuStyles.children.forEach (styleNode) =>
      rawCss = styleNode.children[0].nodeValue
      rawCssLines = rawCssLines.concat(rawCss.split('\n'))
    rawCssLines

  # Converts deku script nodes into a list of lines of lines of code that contain jQuery selectors
  # Used to prefilter hovered lines for selectors.
  extractJQueryLines: (dekuScripts) ->
    _.flatten dekuScripts.children.map (dekuScript) ->
      rawScript = dekuScript.children[0].nodeValue
      _.filter (rawScript.split('\n').map (line) -> (line.match(/^.*\$\(\s*['"].*['"]\s*\).*$/g) or [])[0])
