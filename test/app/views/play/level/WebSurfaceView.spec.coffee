WebSurfaceView = require 'views/play/level/WebSurfaceView'

describe 'WebSurfaceView', ->
  view = new WebSurfaceView({ goalManager: undefined })
  view.iframeLoaded = true
  view.iframe = {contentWindow: {postMessage: ->}}
  studentHtml = """
    <style>
      #some-id {}
      .thing1, .thing2 {
        color: blue;
      }
      div { something: invalid }
    </style>
    <script>
      var divs = $("div")
      divs.toggleClass("some-class")
    </script>
    <div>
      Hi there!
    </div>
  """

  describe 'onHTMLUpdated', ->
    it 'extracts a list of all CSS selectors used', ->
      view.onHTMLUpdated({ studentHtml })
      expect(view.cssSelectors).toEqual(['#some-id', '.thing1, .thing2', 'div', 'div'])
  
  xdescribe 'extractCssSelectors', ->
    beforeEach ->
      e = {html: studentHtml}
      dom = htmlparser2.parseDOM e.html, {}
      body = _.find(dom, name: 'body') ? {name: 'body', attribs: null, children: dom}
      html = _.find(dom, name: 'html') ? {name: 'html', attribs: null, children: [body]}
      { virtualDom, @styles, @scripts } = view.extractStylesAndScripts(view.dekuify html)
      

    it 'extracts a list of all CSS selectors used in CSS code', ->
      extractedSelectors = view.extractCssSelectors(styles, e.html)
      expect(extractedSelectors).toEqual(['#some-id', '.thing1, .thing2', 'div', 'div'])
      

    it 'extracts a list of all CSS selectors used in jQuery calls', ->
      
    
