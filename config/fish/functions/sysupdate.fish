function sysupdate
    onproxy
    paru && paru -Sc --noconfirm
    utilupgrade
    offproxy
end
