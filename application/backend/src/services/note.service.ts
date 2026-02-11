import { AppDataSource } from "../config/database";
import { Note } from "../entities/Note";

export class NoteService {
    private noteRepo = AppDataSource.getRepository(Note);

    async getAllNotes(): Promise<Note[]> {
        return await this.noteRepo.find();
    }

    async getNoteByName(name: string): Promise<Note | null> {
        return await this.noteRepo.findOneBy({ name });
    }

    async createNote(name: string, content: string): Promise<Note> {
        const existing = await this.getNoteByName(name);
        if (existing) {
            throw new Error(`A note with the name '${name}' already exists.`);
        }

        const newNote = this.noteRepo.create({ name, content });
        return await this.noteRepo.save(newNote);
    }

    async updateNote(name: string, content: string): Promise<Note | null> {
        const note = await this.getNoteByName(name);
        if (!note) return null;

        note.content = content;
        return await this.noteRepo.save(note);
    }

    async deleteNote(name: string): Promise<boolean> {
        const result = await this.noteRepo.delete({ name });
        return (result.affected ?? 0) > 0;
    }
}