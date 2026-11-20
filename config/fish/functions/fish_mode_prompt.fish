function fish_mode_prompt
    set -l bg_color 2f2f38
    set -l last_status $status
    set -l pwd_color_bare 88c0d0
    set -l err_color c92a2a

    set -l insert_color 66c0d0
    set -l default_color 5e81ac
    set -l visual_color ebcb8b
    set -l replace_color brmagenta
    set -l fallback_color red
    set -l proxy_color 8686bf
    if test -n "$HTTPS_PROXY"
        set insert_color $proxy_color
        set default_color $proxy_color
        set visual_color $proxy_color
        set replace_color $proxy_color
        set fallback_color $proxy_color
    end

    set_color -o $pwd_color_bare
    set_color -b $bg_color
    echo -n (basename (prompt_pwd))
    if not test $last_status -eq 0
        set_color -o $err_color
        printf ' %s' $last_status
    end
    switch $fish_bind_mode
        case insert
            # set_color --bold "a3be8c"
            set_color --bold $insert_color
            echo -n "  "
        case default
            set_color --bold $default_color
            echo -n " 󰇥 "
        case visual
            set_color --bold $visual_color
            echo -n "  "
        case replace_one
            set_color --bold $replace_color
            echo -n '  '
        case '*'
            set_color --bold $fallback_color
            echo -n '  '
    end
    set_color -b normal
    set_color $bg_color
    echo -n ''
    set_color normal
end
