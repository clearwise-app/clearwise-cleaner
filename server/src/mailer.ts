import nodemailer from "nodemailer";
import type { Config } from "./config.js";

export interface Mailer {
    sendLoginCode(to: string, code: string, locale: string): Promise<void>;
}

export function createMailer(config: Config, log: (msg: string) => void): Mailer {
    if (!config.SMTP_URL) {
        // Development: no SMTP, the code shows up in the server log.
        return {
            async sendLoginCode(to, code) {
                log(`login code for ${to}: ${code}`);
            },
        };
    }
    const transport = nodemailer.createTransport(config.SMTP_URL);
    return {
        async sendLoginCode(to, code, locale) {
            const ru = locale.startsWith("ru");
            const minutes = config.LOGIN_CODE_TTL_MINUTES;
            await transport.sendMail({
                from: config.MAIL_FROM,
                to,
                subject: ru ? `Код входа в Clearwise: ${code}` : `Your Clearwise sign-in code: ${code}`,
                text: ru
                    ? `Ваш код входа: ${code}\n\nОн действует ${minutes} минут. Если вы не запрашивали код, просто проигнорируйте письмо.`
                    : `Your sign-in code: ${code}\n\nIt works for ${minutes} minutes. If you didn't ask for it, ignore this e-mail.`,
            });
        },
    };
}
