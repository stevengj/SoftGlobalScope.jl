"""
SoftGlobalScope is a package that simplifies the [variable scoping rules](https://docs.julialang.org/en/stable/manual/variables-and-scoping/)
for code in *global* scope.   It is intended for interactive shells (the REPL, [IJulia](https://github.com/JuliaLang/IJulia.jl),
etcetera) to make it easier to work interactively with Julia, especially for beginners.

In particular, SoftGlobalScope provides a function `softscope` that can transform Julia code from using the default
"hard" (local) scoping rules to simpler "soft" scoping rules in global scope, and a function `softscope_include_string`
that can evaluate a whole string (similar to `include_string`) using these rules.

For example, if `s` is a global variable in the current module (e.g. `Main`), the following code is an error in
Julia 1.0:
```
for i = 1:10
    s += i     # declares a new local variable `s`
end
```
Instead, you can transform the expression using `softscope` to automatically insert the necessary `global` keyword:
```jl
julia> softscope(Main, :(for i = 1:10
           s += i
       end))
:(for i = 1:10
      #= REPL[3]:2 =#
      global s += i
  end)
```
You can then execute the statement with `eval`.  Alternatively, you can execute an entire sequence of statements
using "soft" global scoping rules via `softscope_include_string`:
```jl
julia> softscope_include_string(Main, \"\"\"
       s = 0
       for i = 1:10
           s += i
       end
       s
       \"\"\")
55
```
(This function works like `include_string`, returning the value of the last evaluated expression.)
"""
module SoftGlobalScope
export softscope, softscope_include_string

using Base.Meta: isexpr

const assignments = Set((:(=), :(+=), :(-=), :(*=), :(/=), :(//=), :(\=), :(^=), :(÷=), :(%=), :(<<=), :(>>=), :(>>>=), :(|=), :(&=), :(⊻=), :($=)))

# extract the local variable name (e.g. `x`) from an assignment expression (e.g. `x=1`)
localvar(ex::Expr) = isexpr(ex, :(=)) ? ex.args[1] : nothing
localvar(ex) = nothing

# Transform expression `ex` to "soft" scoping rules, where `globals` is a collection
# (e.g. `Set`) of global-variable symbols to implicitly qualify with `global`, and
# `insertglobal` is whether to insert the `global` keyword at the top level of
# `ex`.  (Usually, you pass `insertglobal=false` to start with and then it is
# recursively set to `true` for local scopes introduced by `for` etcetera.)
function _softscope(ex::Expr, globals, insertglobal::Bool=false)
    if isexpr(ex, :for) || isexpr(ex, :while)
        return Expr(ex.head, ex.args[1], _softscope(ex.args[2], globals, true))
    elseif isexpr(ex, :try)
        try_clause = _softscope(ex.args[1], globals, true)
        catch_clause = _softscope(ex.args[3], ex.args[2] isa Symbol ? setdiff(globals, ex.args[2:2]) : globals, true)
        finally_clause = _softscope(ex.args[4], globals, true)
        return Expr(:try, try_clause, ex.args[2], catch_clause, finally_clause)
    elseif isexpr(ex, :let)
        letglobals = setdiff(globals, isexpr(ex.args[1], :(=)) ? [ex.args[1].args[1]] : [localvar(ex) for ex in ex.args[1].args])
        return Expr(ex.head, _softscope(ex.args[1], globals, insertglobal),
                             _softscope(ex.args[2], letglobals, true))
    elseif isexpr(ex, :block) || isexpr(ex, :if)
        return Expr(ex.head, _softscope.(ex.args, Ref(globals), insertglobal)...)
    elseif insertglobal && ex.head in assignments && ex.args[1] in globals
        return Expr(:global, Expr(ex.head, ex.args[1], _softscope(ex.args[2], globals, insertglobal)))
    else
        return ex
    end
end
_softscope(ex, globals, insertglobal::Bool=false) = ex

"""
    softscope(m::Module, ast)

Transform the abstract syntax tree `ast` (a quoted Julia expression) to use "soft"
scoping rules for the global variables defined in `m`, returning the new expression.
"""
softscope(m::Module, ast) = _softscope(ast, Set(names(m, all=true)))

"""
    softscope_include_string(m::Module, code::AbstractString, filename::AbstractString="string")

Like [`include_string`](@ref), but evaluates `code` using "soft"
scoping rules for the global variables defined in `m`.
"""
function softscope_include_string(m::Module, code::AbstractString, filename::AbstractString="string")
    # use the undocumented parse_input_line function so that we preserve
    # the filename and line-number information.
    expr = Base.parse_input_line("begin; "*code*"\nend\n", filename=filename)
    retval = nothing
    # expr.args should consist of LineNumberNodes followed by expressions to evaluate
    for i = 2:2:length(expr.args)
        retval = Core.eval(m, softscope(m, Expr(:block, expr.args[i-1:i]...)))
    end
    return retval
end

end # module