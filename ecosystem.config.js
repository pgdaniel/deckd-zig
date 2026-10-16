// pm2 setup for deckd development/testing. Rebuild first, then (re)start:
//
//   cd zig && zig build && cd ..
//   pm2 start ecosystem.config.js     # or: pm2 restart deckd
//   pm2 logs deckd
//
// The systemd user service (systemd/deckd.service) is the production path —
// never run both at once: two deckd processes would share the hidraw node
// and fight over the deck. `systemctl --user stop deckd` before testing.
module.exports = {
  apps: [
    {
      name: "deckd",
      script: "./zig/zig-out/bin/deckd",
      args: ["run"], // broker and pages come from ~/.config/deckd/config.json
      cwd: __dirname,
      autorestart: true,
      restart_delay: 2000,
      // The binary is replaced wholesale by `zig build`; watch mode would
      // restart mid-write, so leave watch off and restart manually.
      watch: false,
    },
  ],
};
