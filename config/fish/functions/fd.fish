function fd
	if command -q /usr/bin/fdfind
		fdfind $argv
	else if command -q /usr/bin/fd
		fd $argv
	end
end
