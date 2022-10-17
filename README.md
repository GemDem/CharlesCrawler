# CharlesCrawler
Powershell script to crawl shared folders in an Active Directory env to find credentials in files

## How to run

 1. Populate "server_list" file with dns / ips (one per line) to crawl

 2. Open a network authenticated powershell 
`runas /netonly /user:USER@DOMAIN.LOCAL powershell`

 3. In the powershell window : verify that everything is ok 
`net view \\DOMAIN.LOCAL` 
Should display something with Netlogon and Sysvol

 4. Launch the script
```
usage : ./charlescrawler.ps1 -c (less|more) -m (dir|file) -t <int>

        -c : Completeness (less or more, default = less).
                less = search less things = less match and false positive, faster
                more = search more things = more match and false positive, longer

        -m : mode (dir or file, default = dir).
                dir = search files wth name matching key words
                file = search key words in each files

        -t : Number of threads (int, default = 50).
        
Examples :
        ./charlescrawler.ps1 : will run with fast speed, dir mode and 50 threads
        ./charlescrawler.ps1 -t 32 : will run with fast speed, dir mode and 32 threads
        ./charlescrawler.ps1 -c more -m file -t 100 : will run with more completeness, file mode and 100 threads
