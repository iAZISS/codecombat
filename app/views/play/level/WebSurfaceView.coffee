CocoView = require 'views/core/CocoView'
template = require 'templates/play/level/web-surface-view'

module.exports = class WebSurfaceView extends CocoView
  id: 'web-surface-view'
  template: template

  subscriptions:
    'tome:html-updated': 'onHTMLUpdated'
    'web-dev:extracted-css-selectors': 'onExtractedCssSelectors'
    'web-dev:hover-line': 'onHoverLine'
    'web-dev:stop-hovering-line': 'onStopHoveringLine'

  initialize: (options) ->
    @goals = (goal for goal in options.goalManager?.goals ? [] when goal.html)
    # Consider https://www.npmjs.com/package/css-select to do this on virtualDom instead of in iframe on concreteDOM
    super(options)

  constructor: ->
    super(arguments...)
    # Make sure SpellView extracts CSS Selectors right after we've initialized
    Backbone.Mediator.publish('web-surface:initialized')

  getRenderData: ->
    _.merge super(), { fullUnsafeContentHostname: serverConfig.fullUnsafeContentHostname }

  afterRender: ->
    super()
    @iframe = @$('iframe')[0]
    $(@iframe).on 'load', (e) =>
      window.addEventListener 'message', @onIframeMessage
      @iframeLoaded = true
      @onIframeLoaded?()
      @onIframeLoaded = null

  # TODO: make clicking Run actually trigger a 'create' update here (for resetting scripts)

  onHTMLUpdated: (e) ->
    unless @iframeLoaded
      return @onIframeLoaded = => @onHTMLUpdated e unless @destroyed
    dom = htmlparser2.parseDOM e.html, {}
    body = _.find(dom, name: 'body') ? {name: 'body', attribs: null, children: dom}
    html = _.find(dom, name: 'html') ? {name: 'html', attribs: null, children: [body]}
    # TODO: pull out the actual scripts, styles, and body/elements they are doing so we can merge them with our initial structure on the other side
    { virtualDom, styles, scripts } = @extractStylesAndScripts(@dekuify html)
    @extractCssSelectors(styles, e.html)
    messageType = if e.create or not @virtualDom then 'create' else 'update'
    @iframe.contentWindow.postMessage {type: messageType, dom: virtualDom, styles, scripts, goals: @goals}, '*'
    @virtualDom = virtualDom

  dekuify: (elem) ->
    return elem.data if elem.type is 'text'
    return null if elem.type is 'comment'  # TODO: figure out how to make a comment in virtual dom
    elem.attribs = _.omit elem.attribs, (val, attr) -> attr.indexOf('<') > -1 # Deku chokes on `<thing <p></p>`
    unless elem.name
      console.log("Failed to dekuify", elem)
      return elem.type
    deku.element(elem.name, elem.attribs, (@dekuify(c) for c in elem.children ? []))
  
  extractStylesAndScripts: (dekuTree) ->
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
    
  combineNodes: (type, nodes) ->
    if _.any(nodes, (node) -> node.type isnt type)
      throw new Error("Can't combine nodes of different types. (Got #{nodes.map (n) -> n.type})")
    children = nodes.map((n) -> n.children).reduce(((a,b) -> a.concat(b)), [])
    if _.isEmpty(children)
      deku.element(type, {})
    else
      deku.element(type, {}, children)

  extractCssSelectors: (dekuStyles, html) ->
    console.log "Extracting CSS selectors!"
    # TODO: Do something better than this hack for detecting which lines are CSS, which are HTML
    console.log "style nodes:", _.flatten dekuStyles.children
    dekuStyles.children.forEach (styleNode) =>
      rawCss = styleNode.children[0].nodeValue
      console.log {rawCss}
      @rawCssLines ?= []
      @rawCssLines = @rawCssLines.concat(rawCss.split("\n"))
    # TODO: Move this hack for extracting CSS selectors
    cssSelectors = _.flatten dekuStyles.children.map (styleNode) ->
      rawCss = styleNode.children[0].nodeValue
      parsedCss = parseAStylesheet(rawCss) # TODO: Don't put this in the global namespace
      parsedCss.value.map (qualifiedRule) =>
        qualifiedRule.prelude.map (token) ->
          if token instanceof WhitespaceToken
            return " "
          else
            return token.value
        .join("").trim()
    # TODO: just do this in WebSurfaceView.onHoverLine?
    # Find all calls to $("...")
    jQuerySelectors = (html.match(/\$\(\s*['"](.*)['"]\s*\)/g) or []).map (jQueryCall) ->
      # Extract the argument (because capture groups don't work with /g)
      jQueryCall.match(/\$\(\s*['"](.*)['"]\s*\)/)[1]
    Backbone.Mediator.publish("web-dev:extracted-css-selectors", { cssSelectors: cssSelectors.concat(jQuerySelectors) })
    null

  onExtractedCssSelectors: ({ @cssSelectors }) ->

  onStopHoveringLine: ->
    @iframe.contentWindow.postMessage({ type: "highlight-css-selector", selector: '' }, '*')

  onHoverLine: ({ row, line }) ->
    if _.contains(@rawCssLines, line)
      # They're hovering over lines of CSS, not HTML
      trimLine = (line.match(/\s(.*)\s*{/)?[1] or line).trim().split(/ +/).join(' ')
      hoveredCssSelector = _.find @cssSelectors, (selector) ->
        trimLine is selector
      @iframe.contentWindow.postMessage({ type: "highlight-css-selector", selector: hoveredCssSelector }, '*')
    else
      # They're not hovering over CSS, so don't highlight anything
      @iframe.contentWindow.postMessage({ type: "highlight-css-selector", selector: '' }, '*')
    null

  onIframeMessage: (event) =>
    origin = event.origin or event.originalEvent.origin
    unless new RegExp("^https?:\/\/#{serverConfig.fullUnsafeContentHostname}$").test origin
      return console.log 'Ignoring message from bad origin:', origin
    unless event.source is @iframe.contentWindow
      return console.log 'Ignoring message from somewhere other than our iframe:', event.source
    switch event.data.type
      when 'goals-updated'
        Backbone.Mediator.publish 'god:new-html-goal-states', goalStates: event.data.goalStates, overallStatus: event.data.overallStatus
      when 'error'
        # NOTE: The line number in this is relative to the script tag, not the user code. The offset is added in SpellView.
        Backbone.Mediator.publish 'web-dev:error', _.pick(event.data, ['message', 'line', 'column', 'url'])
      else
        console.warn 'Unknown message type', event.data.type, 'for message', event, 'from origin', origin

  destroy: ->
    window.removeEventListener 'message', @onIframeMessage
    super()
