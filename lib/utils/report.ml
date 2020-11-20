open Core
open Bistro

type t = {
  title : string ;
  contents : Template_dsl.template ;
}

let make ~title contents = { title ; contents }

let picture_elt format file =
  [%workflow
    let format = match format with
      | `svg -> "svg+xml"
      | `png -> "png"
    in
    let contents =
      In_channel.read_all [%path file]
      |> Base64.encode_exn
    in
    sprintf {|<img src="data:image/%s;base64,%s"/>|} format contents]

let svg x = Template_dsl.string_dep (picture_elt `svg x)
let png x = Template_dsl.string_dep (picture_elt `png x)

let header d =
  let open Template_dsl in
  [%script{|---
title: {{string d.title}}
---|}]

let html_template = Template_dsl.string {|<!DOCTYPE html>
<html $if(lang)$ lang="$lang$" $endif$ dir="ltr">

    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>$if(title)$$title$$endif$</title>
        <link rel="shortcut icon" href="images/favicon.ico" type="image/x-icon">
        <link rel="apple-touch-icon-precomposed" href="images/apple-touch-icon.png">

$if(template_css)$
<link rel="stylesheet" href="$template_css$">
$else$
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/uikit/2.26.4/css/uikit.gradient.css">
$endif$

        <!-- <link rel="stylesheet" href="style.css"> -->
        <link rel="stylesheet" href="https://cdn.rawgit.com/diversen/pandoc-uikit/master/style.css">
        <link href="https://vjs.zencdn.net/5.4.4/video-js.css" rel="stylesheet" />
        <script src="https://code.jquery.com/jquery-2.2.1.min.js"></script>
        <!-- <script src="uikit.js"></script> -->
        <script src="https://cdn.rawgit.com/diversen/pandoc-uikit/master/uikit.js"></script>
        <!-- <script src="scripts.js"></script> -->
        <script src="https://cdn.rawgit.com/diversen/pandoc-uikit/master/scripts.js"></script>
        <!-- <script src="jquery.sticky-kit.js "></script> -->
        <script src="https://cdn.rawgit.com/diversen/pandoc-uikit/master/jquery.sticky-kit.js"></script>

        <meta name="generator" content="pandoc-uikit" />
        $for(author-meta)$
        <meta name="author" content="$author-meta$" />
        $endfor$
        $if(date-meta)$
        <meta name="date" content="$date-meta$" />
        $endif$
        <title>$if(title-prefix)$$title-prefix$ - $endif$$pagetitle$</title>
        <style type="text/css">code{white-space: pre;}</style>
        $if(quotes)$
        <style type="text/css">q { quotes: "“" "”" "‘" "’"; }</style>
        $endif$
        $if(highlighting-css)$
        <style type="text/css">
            $highlighting-css$
        </style>
        $endif$
        $for(css)$
        <link rel="stylesheet" href="$css$" $if(html5)$$else$type="text/css" $endif$/>
              $endfor$
              $if(math)$
              $math$
              $endif$
              $for(header-includes)$
              $header-includes$
              $endfor$
    </head>

    <body>


        <div class="uk-container uk-container-center uk-margin-top uk-margin-large-bottom">

            $if(title)$
            <div class="uk-grid" data-uk-grid-margin>
                <div class="uk-width-1-1">
                    <h1 class="uk-heading-large">$title$</h1>
                    $if(date)$
                    <h3 class="uk-heading-large">$date$</p></h3>
                    $endif$
                    $for(author)$
                    <p class="uk-text-large">$author$</p>
                    $endfor$
                </div>
            </div>
            $endif$

            <div class="uk-grid" data-uk-grid-margin >
                <div class="uk-width-medium-1-4">
                    <div class="uk-overflow-container" data-uk-sticky="{top:25,media: 768}">
                        <div class="uk-panel uk-panel-box menu-begin" >

                            $if(toc)$
                            $toc$
                            $endif$

                        </div>
                    </div>
                </div>

                <div class="uk-width-medium-3-4">
$body$
                </div>
            </div>
$if(analytics)$
            <script>
                  (function(i,s,o,g,r,a,m){i['GoogleAnalyticsObject']=r;i[r]=i[r]||function(){
  (i[r].q=i[r].q||[]).push(arguments)},i[r].l=1*new Date();a=s.createElement(o),
  m=s.getElementsByTagName(o)[0];a.async=1;a.src=g;m.parentNode.insertBefore(a,m)
  })(window,document,'script','https://www.google-analytics.com/analytics.js','ga');

  ga('create', '$analytics$', 'auto');
  ga('send', 'pageview');
$endif$
            <script src="https://vjs.zencdn.net/5.4.4/video.js"></script>
        </div>
    </body>
</html>
|}

let document d = Template_dsl.seq ~sep:"\n" [ header d ; d.contents ]

let to_html d =
  Workflow.shell ~descr:"bistro_utils.report.to_html" Bistro.Shell_dsl.[
      cmd "ln" [ string "-s" ; file_dump html_template ; tmp // "template.html5" ] ;
      cmd "pandoc" [
        opt' "--from" string "markdown+tex_math_single_backslash+tex_math_dollars" ;
        opt' "--to" string "html5" ;
        string "--katex" ;
        opt' "--template" Fn.id (tmp // "template.html5") ;
        opt' "--output" Fn.id dest ;
        string "--toc" ;
        file_dump (document d) ;
      ]
  ]

let build ?np ?mem ?loggers ?allowed_containers ?(bistro_dir = "_bistro") ?collect ~output report =
  let open Bistro_engine in
  let open Lwt in
  let db = Db.init_exn bistro_dir in
  let goal = Workflow.path (to_html report) in
  let sched = Scheduler.create ?np ?mem ?loggers ?allowed_containers ?collect db in
  let report_cache_path = Scheduler.eval sched goal in
  Scheduler.start sched ;
  report_cache_path >>= fun res ->
  Scheduler.stop sched >>= fun () ->
  match res with
  | Ok path ->
    Misc.exec_exn [|"cp" ; path ; output|]
  | Error traces -> (
    let errors = Execution_trace.gather_failures traces in
    prerr_endline (Scheduler.error_report sched errors) ;
    Lwt.fail_with "Some workflow failed!"
  )

let build_main ?np ?mem ?loggers ?allowed_containers ?bistro_dir ?collect ~output report =
  build ?np ?mem ?loggers ?allowed_containers ?bistro_dir ?collect ~output report
  |> Lwt_main.run
