module Server
using AbstractTrees

using ..Protocols

export Session, Smuggler, serve_repl

function io end

struct Session{T}
    entrychannel::Channel
    responsechannel::Channel
    sessionparams::Dict
    evaluatein::Module
    smugglerspecific::T
    protocol::Protocols.Protocol
end
Session(specific, serializer) = Session(Channel(1), Channel(1), Dict(), Main, specific, Protocols.Protocol(serializer, io(specific)))

function Base.show(io::IO, ::Session{T}) where T
    print(io, "Session{$T}()")
end

Base.isopen(s::Session) = isopen(s.smugglerspecific)
function Base.close(s::Session)
    close(s.entrychannel)
    close(s.responsechannel)
    close(s.smugglerspecific)
end
Protocols.dispatchonmessage(s::Session, args...; kwargs...) = Protocols.dispatchonmessage(s.protocol, args...; kwargs...)

struct Smuggler{T,U}
    vessel::T
    serializer::U
    sessions::Set{Session}
end
Base.show(io::IO, s::Smuggler{T,U}) where {T,U} = print(io, "Smuggler($T, $(s.serializer))")
vessel(s::Smuggler) = s.vessel
sessions(s::Smuggler) = s.sessions
Base.isopen(s::Smuggler) = isopen(vessel(s))
function waitsession(::T) where T error("You must implement `REPLSmuggler.waitsession` for type $T")  end
function getsession(smuggler::Smuggler)
    s = Session(waitsession(smuggler), smuggler.serializer)
    push!(smuggler.sessions, s)
    s
end
function Base.close(smuggler::Smuggler, session::Session)
    close(session)
    pop!(smuggler.sessions, session)
end
function Base.close(s::Smuggler) 
    for session in sessions(s)
        close(session)
    end
    empty!(sessions(s))
    close(vessel(s))
end
    
# Heavily inspired by RemoteREPL.jl server.
# Like `sprint()`, but uses IOContext properties `ctx_properties`
#
# This is used to stringify results before sending to the client. This is
# beneficial because:
#   * It allows us to show the user-defined types which exist only on the
#     remote server
#   * It allows us to limit the amount of data transmitted (eg, large arrays
#     are truncated when the :limit IOContext property is set)
function sprint_ctx(f, session)
    io = IOBuffer()
    ctx = IOContext(io, :module=>session.evaluatein)
    f(ctx)
    String(take!(io))
end
function evaluate_entry(session, msgid, file, line, value)
    @debug "Evaluating entry" session file line value
    value = "begin\n" * value * "\nend"
    expr = Meta.parse(value, raise=false, filename=file)
    @debug "Expression before correction" expr
    # Now we put the correct file name and line number on the parsed
    # expression.
    for node in PostOrderDFS(expr)
        if hasproperty(node, :args)
            new_args = map(node.args) do c
                if c isa LineNumberNode
                    LineNumberNode(line+c.line-2, file)
                else
                    c
                end
            end
            node.args = new_args
        end
    end
    @debug "Expression before evaluation" expr
    try
        Base.eval(session.evaluatein, expr)
    catch exc
        @debug "Got an error" exc stacktrace(Base.catch_backtrace())
        stack = stacktrace(Base.catch_backtrace())
        put!(session.responsechannel, Protocols.Error(msgid, exc, stack))
    end
end
function evaluate_entries(session)
    while true
        try
            msgid,file,line,value = take!(session.entrychannel)
            evaluate_entry(session, msgid, file, line, value)
        catch exc
            if exc isa InvalidStateException && !isopen(session.entrychannel)
                break
            elseif exc isa InterruptException
                # Ignore any interrupts which are sent while we're not
                # evaluating a command.
                continue
            else
                rethrow()
            end
        end
    end
end

function treatrequest(::Val{:interrupt}, session, repl_backend, msgid, _)
    @debug "Scheduling an interrupt." session repl_backend
    schedule(repl_backend, InterruptException(); error=true)
    put!(session.responsechannel, Protocols.Result(msgid, "Done."))
end
function treatrequest(::Val{:eval}, session, repl_backend, msgid, file, line, code)
    @debug "Adding an entry." msgid file line session repl_backend
    put!(session.entrychannel, (msgid, file, line, code))    
end
function treatrequest(::Val{:exit}, session, repl_backend, msgid, _)
    @debug "Exiting" session repl_backend
    close(session)
    put!(session.responsechannel, Protocols.Result(msgid, "Done."))
end
function deserialize_requests(session::Session, repl_backend)
    while isopen(session)
        try
            Protocols.dispatchonmessage(session, treatrequest, session, repl_backend)
        catch exc
            if exc isa Protocols.ProtocolException
                put!(session.responsechannel, exc)
            elseif !isopen(session)
                break
            else
                put!(session.responsechannel, Protocols.Error(Protocols.ProtocolException("Server Error.")))
                rethrow()
            end
        end
    end
end
function serialize_responses(session)
    try
        while true
            response = take!(session.responsechannel)
            @debug "Response is" response
            Protocols.serialize(session.protocol, response)
        end
    catch
        if isopen(session)
            rethrow()
        end
    end
end
function serve_repl_session(session)
    put!(session.responsechannel, Protocols.Handshake())
    @sync begin
        repl_backend = @async try
            evaluate_entries(session)
        catch exc
            @error "RemoteREPL backend crashed" exception=exc,catch_backtrace()
        finally
            close(session)
        end

        @async try
            serialize_responses(session)
        catch exc
            @error "RemoteREPL responder crashed" exception=exc,catch_backtrace()
        finally
            close(session)
        end

        try
            deserialize_requests(session, repl_backend)
        catch exc
            @error "RemoteREPL frontend crashed" exception=exc,catch_backtrace()
            rethrow()
        finally
            close(session)
        end
    end
end
function serve_repl(smuggler::Smuggler)
    @async try
        while isopen(smuggler)
            session = getsession(smuggler)
            @async try
                serve_repl_session(session)
            catch exception
                if !(exception isa EOFError && !isopen(session))
                    @warn "Something went wrong evaluating client command" exception=exception,catch_backtrace()
                end
            finally
                @info "REPL client exited" session
                close(smuggler, session)
            end
            @info "New client connected" session
        end
    catch exception
        if exception isa Base.IOError && !isopen(smuggler)
            # Ok - server was closed
            return
        end
        @error "Unexpected server failure" smuggler exception=exception,catch_backtrace()
        rethrow()
    finally
        close(smuggler)
    end
end

end
