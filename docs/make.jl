using Documenter

push!(LOAD_PATH,  "../../src")

using GenieSessionFileSession

makedocs(
    sitename = "GenieSessionFileSession - FileSession for Genie",
    format = Documenter.HTML(prettyurls = false),
    pages = [
        "Home" => "index.md",
        "GenieSessionFileSession API" => [
          "GenieSessionFileSession" => "API/geniesessionfilesession.md",
        ]
    ],
)

deploydocs(
  repo = "github.com/GenieFramework/GenieSessionFileSession.jl.git",
)
