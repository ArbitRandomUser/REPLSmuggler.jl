module SocketSmugglers
using Sockets

using ..REPLSmuggler
using REPLSmuggler.Server

export SocketSmuggler

struct SocketSmuggler
    path::String
    server::Base.IOServer
end
function SocketSmuggler(path)
    server = listen(path)
    @info "Ahoy, now smuggling from socket $path."
    SocketSmuggler(path, server)
end
function SocketSmuggler()
    path = ""
    if Sys.isunix()
        path = REPLSmuggler.yer_name()
        while ispath(path)
            path = REPLSmuggler.yer_name()
        end
        mkpath(dirname(path))
        path
    elseif Sys.iswindows()
        path = REPLSmuggler.yer_name(joinpath=false)
        path = replace("😭😭.😭pipe😭$path", "😭"=>"\\")
    else
        error("Can't create a UNIX Socket or equivalent on your platform.")
    end
    SocketSmuggler(path)
end
Base.isopen(s::SocketSmuggler) = isopen(s.server)
Base.close(s::SocketSmuggler) = close(s.server)

function REPLSmuggler.Server.waitsession(s::Server.Smuggler{SocketSmuggler, U}) where U
    socketsmuggler = REPLSmuggler.Server.vessel(s)
    accept(socketsmuggler.server)
end

Server.io(s::Base.PipeEndpoint) = s

end
