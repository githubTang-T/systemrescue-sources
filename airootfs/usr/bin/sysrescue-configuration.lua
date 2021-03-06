#!/usr/bin/env lua
--
-- Author: Francois Dupoux
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- SystemRescue configuration processing script
--
-- This script uses the SystemRescue yaml configuration files and the options
-- passed on the boot command line to override the default configuration.
-- It processes yaml configuration files in the alphabetical order, and each option
-- found in a file override the options defined earlier. Options passed on the
-- boot command like take precedence over configuration options defined in files.
-- At the end it writes the effective configuration to a JSON file which is meant
-- to be ready by any initialisation script which needs to know the configuration.
-- Shell scripts can read values from the JSON file using a command such as:
-- jq --raw-output '.global.copytoram' /etc/sysrescue/sysrescue-effective-config.json
-- This script requires the following lua packages to run on Arch Linux:
-- sudo pacman -Sy lua lua-yaml lua-dkjson lua-http

-- ==============================================================================
-- Import modules
-- ==============================================================================
local lfs = require('lfs')
local yaml = require('yaml')
local json = require("dkjson")
local request = require("http.request")

-- ==============================================================================
-- Utility functions
-- ==============================================================================
-- Read a file and return all its contents
function read_file_contents(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- Return true if the item is present in the list or false otherwise
function item_in_list(item, list)
    for _, curitem in ipairs(list) do
        if (curitem == item) then
            return true
        end
    end
    return false
end

-- Return the number of items in a table
function get_table_size(mytable)
    size = 0
    for _ in pairs(mytable) do
        size = size + 1
    end
    return size
end

-- Return a list of files with a yaml extension found in the directory 'dirname'
-- If 'filenames' is an empty list then it will return all files which have been found
-- If 'filenames' is not empty then it will only return files with a name present in the list
function list_config_files(dirname, filenames)
    local results = {}
    for curfile in lfs.dir(dirname) do
        fullpath = dirname.."/"..curfile
        filetype = lfs.attributes(fullpath, "mode")
        if (filetype == "file") and curfile:match(".[Yy][Aa][Mm][Ll]$") then
            if (get_table_size(filenames) == 0) or item_in_list(curfile, filenames) then
                table.insert(results, fullpath)
            end
        end
    end
    table.sort(results)
    return results
end

-- Attempt to find the option 'optname' on the boot command line and return its value
-- If 'multiple' is false then it will return the value of the last occurence found or nil
-- If 'multiple' is true then it will return a list of all values passed or an empty list
function search_cmdline_option(optname, multiple)
    local result_single = nil
    local result_multiple = {}
    local cmdline = read_file_contents("/proc/cmdline")
    for curopt in cmdline:gmatch("%S+") do
        optmatch1 = string.match(curopt, "^"..optname.."$")
        _, _, optmatch2 = string.find(curopt, "^"..optname.."=([^%s]+)$")
        if (optmatch1 ~= nil) or (optmatch2 == 'y') or (optmatch2 == 'yes') or (optmatch2 == 'true') then
            result_single = true
            table.insert(result_multiple, true)
        elseif (optmatch2 == 'n') or (optmatch2 == 'no') or (optmatch2 == 'false') then
            result_single = false
            table.insert(result_multiple, false)
        elseif (optmatch2 ~= nil) then
            result_single = optmatch2
            table.insert(result_multiple, optmatch2)
        end
    end
    if multiple == true then
        return result_multiple
    else
        return result_single
    end
end

-- Process a block of yaml configuration and override the current configuration with new values
function process_yaml_config(curconfig)
    if (curconfig == nil) or (type(curconfig) ~= "table") then
        io.stderr:write(string.format("This is not valid yaml, it will be ignored\n"))
        return false
    end
    for scope, entries in pairs(config) do
        for key, val in pairs(entries) do
            if (curconfig[scope] ~= nil) and (curconfig[scope][key] ~= nil) then
                print("- Overriding config['"..scope.."']['"..key.."'] with the value from the yaml file")
                config[scope][key] = curconfig[scope][key]
            end
        end
    end
    return true
end

-- Download a file over http/https and return the contents of the file or nil if it fails
function download_file(fileurl)
    local req_timeout = 10
    local req = request.new_from_uri(fileurl)
    local headers, stream = req:go(req_timeout)

    if headers == nil then
        io.stderr:write(string.format("Failed to download %s: Could not connect\n", fileurl))
        return nil
    end

    status = headers:get(":status")
    if status ~= '200' then
        io.stderr:write(string.format("Failed to download %s: Received HTTP code %s\n", fileurl, status))
        return nil
    end

    local body, err = stream:get_body_as_string()
    if not body and err then
        io.stderr:write(string.format("Failed to download %s: Error %s\n", fileurl, tostring(err)))
        return nil
    end

    return body
end

-- ==============================================================================
-- Initialisation
-- ==============================================================================
errcnt = 0

-- ==============================================================================
-- Define the default configuration
-- ==============================================================================
print ("====> Define the default configuration ...")
config = {
    ["global"] = {
        ['copytoram'] = false,
        ['checksum'] = false,
        ['loadsrm'] = false,
        ['late_load_srm'] = "",
        ['dostartx'] = false,
        ['dovnc'] = false,
        ['noautologin'] = false,
        ['nofirewall'] = false,
        ['rootshell'] = "",
        ['rootpass'] = "",
        ['rootcryptpass'] = "",
        ['setkmap'] = "",
        ['vncpass'] = "",
    },
    ["autorun"] = {
        ['ar_disable'] = false,
        ['ar_nowait'] = false,
        ['ar_nodel'] = false,
        ['ar_ignorefail'] = false,
        ['ar_attempts'] = 1,
        ['ar_source'] = "",
        ['ar_suffixes'] = "0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F",
    },
    ["sysconfig"] = {
        ["ca-trust"] = {},
    },
}

-- ==============================================================================
-- Override the configuration with values from yaml files
-- ==============================================================================
print ("====> Overriding the default configuration with values from yaml files ...")
confdirs = {"/run/archiso/bootmnt/sysrescue.d", "/run/archiso/copytoram/sysrescue.d"}
conffiles = search_cmdline_option("sysrescuecfg", true)

-- Process local yaml configuration files
for _, curdir in ipairs(confdirs) do
    if lfs.attributes(curdir, "mode") == "directory" then
        print("Searching for yaml configuration files in "..curdir.." ...")
        for _, curfile in ipairs(list_config_files(curdir, conffiles)) do
            print(string.format("Processing local yaml configuration file: %s ...", curfile))
            local curconfig = yaml.loadpath(curfile)
            --print("++++++++++++++\n"..yaml.dump(curconfig).."++++++++++++++\n")
            if process_yaml_config(curconfig) == false then
                errcnt = errcnt + 1
            end
        end
    else
        print("Directory "..curdir.." was not found so it has been ignored")
    end
end

-- Process remote yaml configuration files
print("Searching for remote yaml configuration files ...")
for _, curfile in ipairs(conffiles) do
    if string.match(curfile, "^https?://") then
        print(string.format("Processing remote yaml configuration file: %s ...", curfile))
        local contents = download_file(curfile)
        if (contents == nil) or (process_yaml_config(yaml.load(contents)) == false) then
            errcnt = errcnt + 1
        end
    end
end

-- ==============================================================================
-- Override the configuration with values passed on the boot command line
-- ==============================================================================
print ("====> Overriding the configuration with options passed on the boot command line ...")
for _, scope in ipairs({"global", "autorun"}) do
    for key,val in pairs(config[scope]) do
        optresult = search_cmdline_option(key, false)
        if optresult == true then
            print("- Option '"..key.."' has been enabled on the boot command line")
            config[scope][key] = optresult
        elseif optresult == false then
            print("- Option '"..key.."' has been disabled on the boot command line")
            config[scope][key] = optresult
        elseif optresult ~= nil then
            print("- Option '"..key.."' has been defined as '"..optresult.."' on the boot command line")
            config[scope][key] = optresult
        end
    end
end

-- ==============================================================================
-- Print the effective configuration
-- ==============================================================================
print ("====> Printing the effective configuration")
local jsoncfgtxt = json.encode (config, { indent = true })
print (jsoncfgtxt)

-- ==============================================================================
-- Write the effective configuration to a JSON file
-- ==============================================================================
print ("====> Writing the effective configuration to a JSON file ...")
output_location = "/etc/sysrescue"
output_filename = "sysrescue-effective-config.json"
output_fullpath = output_location.."/"..output_filename
lfs.mkdir(output_location)
jsoncfgfile = io.open(output_fullpath, "w")
if jsoncfgfile == nil then
    io.stderr:write(string.format("ERROR: Failed to create effective configuration file in %s\n", output_fullpath))
    os.exit(1)
end
jsoncfgfile:write(jsoncfgtxt)
jsoncfgfile:close()
os.execute("chmod 700 "..output_location)
os.execute("chmod 600 "..output_fullpath)
print ("Effective configuration has been written to "..output_fullpath)

-- ==============================================================================
-- Error handling
-- ==============================================================================
if errcnt == 0 then
    print ("SUCCESS: Have successfully completed the processing of the configuration")
    os.exit(0)
else
    io.stderr:write(string.format("FAILURE: Have completed the processing of the configuration with %d errors\n", errcnt))
    os.exit(1)
end
